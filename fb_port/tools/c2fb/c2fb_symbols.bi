/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_symbols.bi

    Purpose:

        Own the translation-unit C symbol index and body-specific signature metadata.

    Responsibilities:

        - Give generic-header bindings and body procedures one shared C-name index.
        - Keep generic-header bindings separate from body signature state.
        - Retain body procedure types, callback signatures, and fixed array typedef extents.
        - Index file-scope function-pointer objects for typed indirect calls.
        - Preserve supported translation-unit-local scalar and pointer state.
        - Index explicitly renamed file-scope record arrays for body candidates.
        - Keep body-only call-name overrides and definition availability together.

    This file intentionally does NOT contain:

        - FreeBASIC project call-signature indexing.
        - Structure layout generation or C preprocessor evaluation.
        - Runtime SQLite state or function-body lowering.
'/

' The command-line converter processes files serially. C-body symbol tables
' are rebuilt for each input file and remain read-only during expression parsing.
Declare Function CBodyParameterType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal procedureName As String, ByVal parameterIndex As Long _
) As String

Declare Function CBodyFreeBasicProcedureNameInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As String
Declare Function CBodyCallName( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal procedureName As String _
) As String

Private Sub ResetC2fbSymbolTableInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal initialCapacity As Long _
)
    If initialCapacity <= 0 OrElse initialCapacity > MAX_C2FB_SYMBOLS Then _
        ReportError("invalid initial C symbol-table capacity")
    ReDim translation.symbolTable.symbols(0 To initialCapacity - 1)
    translation.symbolTable.symbolCount = 0
    ResetC2fbStringIndexMap(translation.symbolTable.nameIndex)
End Sub

Private Function EnsureC2fbSymbolInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByVal cName As String, _
    ByVal freeBasicName As String, ByVal kind As C2fbSymbolKind _
) As Long
    ' Merge declarations by C identity so header and body lowering cannot
    ' silently assign different FreeBASIC names to the same source symbol.
    If sourceName = "" Then Return -1
    Dim symbolIndex As Long = C2fbSymbolIndexInContext(translation, sourceName)
    If symbolIndex < 0 Then
        If translation.symbolTable.symbolCount >= MAX_C2FB_SYMBOLS Then _
            ReportError("translation unit exceeds the configured symbol limit")
        If translation.symbolTable.symbolCount > UBound(translation.symbolTable.symbols) Then _
            ReDim Preserve translation.symbolTable.symbols( _
                0 To UBound(translation.symbolTable.symbols) * 2 + 1)
        symbolIndex = translation.symbolTable.symbolCount
        If AddC2fbStringIndexMapEntry( _
            translation.symbolTable.nameIndex, sourceName, symbolIndex) <> -1 Then _
            ReportError("translation unit exceeds the configured symbol limit")
        translation.symbolTable.symbolCount += 1
        translation.symbolTable.symbols(symbolIndex).sourceName = sourceName
    End If

    With translation.symbolTable.symbols(symbolIndex)
        If cName <> "" Then
            If .cName = "" Then
                .cName = cName
            ElseIf .cName <> cName Then
                .ambiguous = -1
            End If
        End If
        If freeBasicName <> "" Then
            If .freeBasicName = "" Then
                .freeBasicName = freeBasicName
            ElseIf .freeBasicName <> freeBasicName Then
                .ambiguous = -1
            End If
        End If
        If kind <> 0 Then
            If .kind = 0 Then
                .kind = kind
            ElseIf .kind <> kind Then
                .ambiguous = -1
            End If
        End If
    End With
    Return symbolIndex
End Function

Private Function LookupCBodyTypeAliasInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal typeName As String, _
    ByRef pointerCount As Long, _
    ByRef isConst As Long _
) As String
    For i As Long = 0 To translation.body.aliasCount - 1
        If translation.body.aliases(i).name = typeName Then
            If translation.body.aliases(i).ambiguous <> 0 Then Return ""
            If translation.body.aliases(i).isArray <> 0 Then Return ""
            pointerCount += translation.body.aliases(i).pointerCount
            If translation.body.aliases(i).isConst <> 0 Then isConst = -1
            Return translation.body.aliases(i).baseType
        End If
    Next
    Return ""
End Function

Private Function LookupCBodyCallbackTypeAlias( _
    ByRef translation As C2fbTranslationContext, ByVal typeName As String _
) As String
    For i As Long = 0 To translation.body.aliasCount - 1
        If translation.body.aliases(i).name = typeName Then
            If translation.body.aliases(i).ambiguous <> 0 Then Return ""
            Return translation.body.aliases(i).callbackType
        End If
    Next
    Return ""
End Function

Private Function CBodyProcedureIndex( _
    ByRef translation As C2fbTranslationContext, ByVal procedureName As String _
) As Long
    Dim symbolIndex As Long = _
        C2fbSymbolIndexInContext(translation, procedureName)
    If symbolIndex < 0 OrElse _
       translation.symbolTable.symbols(symbolIndex).body.isDeclared = 0 Then Return -1
    Return symbolIndex
End Function

Private Function CBodyExternalObjectIndex( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As Long
    For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
        With translation.body.externalObjects(objectIndex)
            If .sourceName = sourceName AndAlso .isAmbiguous = 0 Then _
                Return objectIndex
        End With
    Next
    Return -1
End Function

Private Function CBodyArrayTypeAliasIndexInContext( _
    ByRef translation As C2fbTranslationContext, ByVal typeName As String _
) As Long
    For aliasIndex As Long = 0 To translation.body.aliasCount - 1
        With translation.body.aliases(aliasIndex)
            If .name = typeName AndAlso .isArray <> 0 AndAlso _
               .ambiguous = 0 AndAlso .arrayCount > 0 AndAlso _
               .arrayElementType <> "" Then Return aliasIndex
        End With
    Next
    Return -1
End Function

Private Sub RecordCBodyPointerToArrayParameterInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal procedureName As String, ByVal parameterIndex As Long, _
    ByVal parameterName As String, _
    ByVal arrayElementType As String, ByVal arrayElementCount As Long, _
    ByVal isConst As Long _
)
    For entryIndex As Long = 0 To _
        translation.body.pointerToArrayParameterCount - 1
        With translation.body.pointerToArrayParameters(entryIndex)
            If .procedureName <> procedureName OrElse _
               .parameterIndex <> parameterIndex Then Continue For
            If .arrayElementType <> arrayElementType OrElse _
               .arrayElementCount <> arrayElementCount OrElse _
               .isConst <> isConst Then .isAmbiguous = -1
            Exit Sub
        End With
    Next
    If translation.body.pointerToArrayParameterCount >= _
       MAX_C2FB_BODY_TYPE_ALIASES Then _
        ReportError("source exceeds the configured pointer-to-array parameter limit")
    If translation.body.pointerToArrayParameterCount > _
       UBound(translation.body.pointerToArrayParameters) Then _
        ReDim Preserve translation.body.pointerToArrayParameters( _
            0 To UBound(translation.body.pointerToArrayParameters) * 2 + 1)
    With translation.body.pointerToArrayParameters( _
        translation.body.pointerToArrayParameterCount)
        .procedureName = procedureName
        .parameterIndex = parameterIndex
        .parameterName = parameterName
        .arrayElementType = arrayElementType
        .arrayElementCount = arrayElementCount
        .isConst = isConst
    End With
    translation.body.pointerToArrayParameterCount += 1
End Sub

Private Function CBodyPointerToArrayParameterIndexInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal procedureName As String, ByVal parameterName As String _
) As Long
    For parameterIndex As Long = 0 To _
        translation.body.pointerToArrayParameterCount - 1
        With translation.body.pointerToArrayParameters(parameterIndex)
            If .procedureName = procedureName AndAlso _
               .parameterName = parameterName AndAlso .isAmbiguous = 0 Then _
                Return parameterIndex
        End With
    Next
    Return -1
End Function

Private Function CBodyPointerToArrayParameterIndexByPositionInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal procedureName As String, ByVal parameterIndex As Long _
) As Long
    For entryIndex As Long = 0 To _
        translation.body.pointerToArrayParameterCount - 1
        With translation.body.pointerToArrayParameters(entryIndex)
            If .procedureName = procedureName AndAlso _
               .parameterIndex = parameterIndex AndAlso .isAmbiguous = 0 Then _
                Return entryIndex
        End With
    Next
    Return -1
End Function

Private Function CBodyDirectPointerToArrayParameterInContext( _
    ByRef translation As C2fbTranslationContext, _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByVal parameterName As String, ByVal parameterType As String, _
    ByRef arrayElementType As String, ByRef arrayElementCount As Long, _
    ByRef arrayElementIsConst As Long _
) As Long
    arrayElementType = ""
    arrayElementCount = 0
    arrayElementIsConst = 0
    Dim parameterNameIndex As Long = -1
    For tokenIndex As Long = firstToken To lastToken
        If tokens(tokenIndex) = parameterName Then
            parameterNameIndex = tokenIndex
            Exit For
        End If
    Next
    If parameterNameIndex < 0 OrElse _
       Right(parameterType, 4) <> " Ptr" Then Return 0

    Dim elementType As String = SimplePointeeType(parameterType)
    If elementType = "" Then Return 0
    Dim parameterRank As Long = 0
    Dim rowElementCount As LongInt = 1
    Dim tokenPosition As Long = parameterNameIndex + 1
    While tokenPosition <= lastToken AndAlso tokens(tokenPosition) = "["
        Dim closingBracket As Long = -1
        Dim nestedBracketDepth As Long = 0
        For scanIndex As Long = tokenPosition + 1 To lastToken
            If tokens(scanIndex) = "[" Then
                nestedBracketDepth += 1
            ElseIf tokens(scanIndex) = "]" Then
                If nestedBracketDepth = 0 Then
                    closingBracket = scanIndex
                    Exit For
                End If
                nestedBracketDepth -= 1
            End If
        Next
        If closingBracket < 0 Then Return 0
        parameterRank += 1
        If parameterRank > 1 Then
            Dim boundText As String
            For boundIndex As Long = tokenPosition + 1 To closingBracket - 1
                If boundText <> "" Then boundText &= " "
                boundText &= tokens(boundIndex)
            Next
            Dim dimensionCount As Long
            If boundText = "" OrElse _
               (EvaluateSimpleArrayBound( _
                    boundText, dimensionCount, MAX_GENERIC_ARRAY_COUNT) = 0 AndAlso _
                EvaluateGenericBodyArrayBound( _
                    translation, boundText, dimensionCount, _
                    MAX_GENERIC_ARRAY_COUNT) = 0) OrElse _
               dimensionCount < 1 OrElse _
               rowElementCount > _
                   (MAX_GENERIC_ARRAY_COUNT \ dimensionCount) Then Return 0
            rowElementCount *= dimensionCount
        End If
        tokenPosition = closingBracket + 1
    Wend
    If parameterRank < 2 Then Return 0
    arrayElementType = elementType
    arrayElementCount = CLng(rowElementCount)
    arrayElementIsConst = CInt(Left(elementType, 6) = "Const ") * -1
    Return -1
End Function

Private Function CBodyExternalObjectNameConflict( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal freeBasicName As String _
) As Long
    Dim foldedName As String = LCase(freeBasicName)
    For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
        If LCase(translation.symbolTable.symbols(symbolIndex).freeBasicName) = _
           foldedName Then Return -1
    Next
    For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
        If LCase(translation.body.externalObjects(objectIndex).freeBasicName) = _
           foldedName OrElse _
           LCase(translation.body.externalObjects(objectIndex).storageName) = _
           foldedName Then Return -1
    Next
    For nameIndex As Long = 0 To catalog.callableNameCount - 1
        If LCase(catalog.callableNames(nameIndex)) = foldedName Then Return -1
    Next
    For nameIndex As Long = 0 To catalog.localDeclarationNameCount - 1
        If LCase(catalog.localDeclarationNames(nameIndex)) = foldedName Then Return -1
    Next
    For aliasIndex As Long = 0 To translation.body.aliasCount - 1
        If LCase(translation.body.aliases(aliasIndex).name) = foldedName OrElse _
           LCase(translation.body.aliases(aliasIndex).baseType) = foldedName Then _
            Return -1
    Next
    For aliasIndex As Long = 0 To catalog.bodyTypeAliasCount - 1
        If LCase(catalog.bodyTypeAliases(aliasIndex).aliasName) = foldedName OrElse _
           LCase(catalog.bodyTypeAliases(aliasIndex).targetName) = foldedName Then _
            Return -1
    Next
    Return 0
End Function

Private Function CBodyExternalObjectFreeBasicName( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As String
    Dim reusedName As String = GenericStaticObjectReuseInPolicy( _
        translation.genericC.policy, sourceName)
    If reusedName <> "" Then Return reusedName

    Dim result As String = _
        GenericSymbolRenameInPolicy(translation.genericC.policy, sourceName)
    If result = "" Then
        Dim prefix As String = translation.genericC.policy.generatedNamePrefix
        If prefix = "" Then prefix = "c2fb_"
        result = prefix & "global_" & sourceName
    End If

    Do While CBodyExternalObjectNameConflict( _
        translation, catalog, result) <> 0
        result &= "_"
    Loop
    Return result
End Function

Private Function CBodyExternalProcedureFreeBasicName( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As String
    Dim result As String = _
        GenericProcedureRenameInPolicy(translation.genericC.policy, sourceName)
    If result = "" Then
        Dim prefix As String = translation.genericC.policy.generatedNamePrefix
        If prefix = "" Then prefix = "c2fb_"
        result = prefix & "external_" & sourceName
    End If

    Do While CBodyExternalObjectNameConflict( _
        translation, catalog, result) <> 0
        result &= "_"
    Loop
    Return result
End Function

Private Function CBodyExternalArrayInitializerCount( _
    tokens() As String, ByVal tokenCount As Long, _
    ByVal firstToken As Long, ByRef arrayCount As Long _
) As Long
    arrayCount = 0
    Dim assignmentPosition As Long = -1
    For tokenIndex As Long = firstToken To tokenCount - 1
        If tokens(tokenIndex) = "=" Then
            assignmentPosition = tokenIndex
            Exit For
        End If
    Next
    If assignmentPosition < 0 Then Return 0

    Dim initializerOpen As Long = -1
    For searchIndex As Long = assignmentPosition + 1 To tokenCount - 1
        If tokens(searchIndex) = "{" Then
            initializerOpen = searchIndex
            Exit For
        End If
    Next
    If initializerOpen < 0 Then Return 0

    Dim braceDepth As Long = 0
    Dim parenthesisDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim elementCount As Long = 0
    Dim hasElement As Long = 0
    Dim foundEnd As Long = 0
    For tokenIndex As Long = initializerOpen To tokenCount - 1
        Dim token As String = tokens(tokenIndex)
        Select Case token
        Case "{"
            braceDepth += 1
            If braceDepth = 2 AndAlso parenthesisDepth = 0 AndAlso _
               bracketDepth = 0 Then hasElement = -1
        Case "}"
            If braceDepth = 1 AndAlso parenthesisDepth = 0 AndAlso _
               bracketDepth = 0 Then
                If hasElement <> 0 Then elementCount += 1
                foundEnd = -1
                Exit For
            End If
            If braceDepth <= 0 Then Return 0
            braceDepth -= 1
        Case "(": parenthesisDepth += 1
        Case ")": If parenthesisDepth > 0 Then parenthesisDepth -= 1
        Case "[": bracketDepth += 1
        Case "]": If bracketDepth > 0 Then bracketDepth -= 1
        Case ","
            If braceDepth = 1 AndAlso parenthesisDepth = 0 AndAlso _
               bracketDepth = 0 Then
                If hasElement <> 0 Then elementCount += 1
                hasElement = 0
            ElseIf braceDepth = 1 Then
                hasElement = -1
            End If
        Case Else
            If braceDepth = 1 Then hasElement = -1
        End Select
        If elementCount > MAX_GENERIC_ARRAY_COUNT Then Return 0
    Next
    If foundEnd = 0 OrElse elementCount < 1 Then Return 0
    arrayCount = elementCount
    Return -1
End Function

Private Function CBodyExternalArrayInitializerCountFromText( _
    ByRef translation As C2fbTranslationContext, _
    tokens() As String, ByVal tokenCount As Long, _
    ByVal firstToken As Long, ByVal sourceInitializer As String, _
    ByRef arrayCount As Long _
) As Long
    arrayCount = 0
    Dim sourceValues() As String
    Dim sourceValueCount As Long
    If SplitGenericStaticInitializerList( _
        sourceInitializer, sourceValues(), sourceValueCount) <> 0 AndAlso _
       sourceValueCount > 0 Then
        Dim nextIndex As Long = 0
        Dim maximumIndex As Long = -1
        For valueIndex As Long = 0 To sourceValueCount - 1
            Dim firstIndex As Long
            Dim lastIndex As Long
            Dim elementText As String
            Dim designatorStatus As Long = ParseGenericArrayInitializerDesignator( _
                translation, sourceValues(valueIndex), firstIndex, lastIndex, _
                elementText)
            If designatorStatus < 0 Then Return 0
            If designatorStatus = 0 Then
                firstIndex = nextIndex
                lastIndex = firstIndex
            End If
            If firstIndex < 0 OrElse lastIndex < firstIndex OrElse _
               lastIndex >= MAX_GENERIC_ARRAY_COUNT Then Return 0
            If lastIndex > maximumIndex Then maximumIndex = lastIndex
            nextIndex = lastIndex + 1
        Next
        If maximumIndex < 0 Then Return 0
        arrayCount = maximumIndex + 1
        Return -1
    End If
    ' Fall back to tokens for initializer forms outside the static-list parser.
    Return CBodyExternalArrayInitializerCount( _
        tokens(), tokenCount, firstToken, arrayCount)
End Function

Private Function CBodyInlineRecordArrayCount( _
    ByVal recordTail As String, ByVal sourceName As String, _
    ByRef arrayCount As Long _
) As Long
    arrayCount = 0
    Dim namePosition As Long = InStr(recordTail, sourceName)
    If namePosition = 0 Then Return 0
    Dim beforeName As Long = 0
    Dim afterName As Long = 0
    If namePosition > 1 Then beforeName = Asc(recordTail, namePosition - 1)
    If namePosition + Len(sourceName) <= Len(recordTail) Then _
        afterName = Asc(recordTail, namePosition + Len(sourceName))
    If (beforeName <> 0 AndAlso IsIdentifierPart(beforeName) <> 0) OrElse _
       (afterName <> 0 AndAlso IsIdentifierPart(afterName) <> 0) Then Return 0

    Dim position As Long = namePosition + Len(sourceName)
    SkipCSpaces(recordTail, position)
    If Mid(recordTail, position, 1) <> "[" Then Return 0
    position += 1
    SkipCSpaces(recordTail, position)
    If Mid(recordTail, position, 1) <> "]" Then Return 0
    position += 1
    SkipCSpaces(recordTail, position)
    If Mid(recordTail, position, 1) <> "=" Then Return 0
    position += 1
    SkipCSpaces(recordTail, position)
    If Mid(recordTail, position, 1) <> "{" Then Return 0

    Dim braceDepth As Long = 0
    Dim parenthesisDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    Dim elementCount As Long = 0
    Dim hasElement As Long = 0
    Dim foundEnd As Long = 0
    For scanPosition As Long = position To Len(recordTail)
        Dim currentByte As Long = Asc(recordTail, scanPosition)
        If quoteByte <> 0 Then
            If braceDepth = 1 Then hasElement = -1
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            Continue For
        End If
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quoteByte = currentByte
            If braceDepth = 1 Then hasElement = -1
        ElseIf currentByte = Asc("{") Then
            If braceDepth = 1 Then hasElement = -1
            braceDepth += 1
        ElseIf currentByte = Asc("}") Then
            If braceDepth = 1 AndAlso parenthesisDepth = 0 AndAlso _
               bracketDepth = 0 Then
                If hasElement <> 0 Then elementCount += 1
                foundEnd = -1
                Exit For
            End If
            If braceDepth <= 0 Then Return 0
            braceDepth -= 1
        ElseIf currentByte = Asc("(") Then
            parenthesisDepth += 1
            If braceDepth = 1 Then hasElement = -1
        ElseIf currentByte = Asc(")") Then
            If parenthesisDepth > 0 Then parenthesisDepth -= 1
        ElseIf currentByte = Asc("[") Then
            bracketDepth += 1
            If braceDepth = 1 Then hasElement = -1
        ElseIf currentByte = Asc("]") Then
            If bracketDepth > 0 Then bracketDepth -= 1
        ElseIf currentByte = Asc(",") AndAlso braceDepth = 1 AndAlso _
               parenthesisDepth = 0 AndAlso bracketDepth = 0 Then
            If hasElement <> 0 Then elementCount += 1
            hasElement = 0
        ElseIf braceDepth = 1 AndAlso IsSpaceByte(currentByte) = 0 Then
            hasElement = -1
        End If
    Next
    If foundEnd = 0 OrElse elementCount < 1 OrElse _
       elementCount > MAX_GENERIC_ARRAY_COUNT Then Return 0
    arrayCount = elementCount
    Return -1
End Function

Private Function CBodyFixedExternalArrayDimensions( _
    ByRef translation As C2fbTranslationContext, _
    tokens() As String, ByVal tokenCount As Long, _
    ByVal commonTypeTokenCount As Long, ByVal sourceName As String, _
    ByVal sourceInitializer As String, dimensions() As Long, _
    ByRef arrayCount As Long, _
    ByRef arrayRank As Long, ByRef arrayDimensions As String, _
    ByRef isUnsizedArray As Long _
) As Long
    arrayCount = 0
    arrayRank = 0
    arrayDimensions = ""
    isUnsizedArray = 0
    Dim namePosition As Long = -1
    For tokenIndex As Long = commonTypeTokenCount To tokenCount - 1
        If tokens(tokenIndex) = sourceName Then
            namePosition = tokenIndex
            Exit For
        End If
    Next
    If namePosition < 0 OrElse namePosition + 1 >= tokenCount OrElse _
       tokens(namePosition + 1) <> "[" Then Return 0

    ReDim dimensions(0 To MAX_GENERIC_ARRAY_RANK - 1)
    Dim position As Long = namePosition + 1
    Dim totalCount As LongInt = 1
    While position < tokenCount AndAlso tokens(position) = "["
        If arrayRank >= MAX_GENERIC_ARRAY_RANK Then Return 0
        position += 1
        Dim boundExpression As String
        While position < tokenCount AndAlso tokens(position) <> "]"
            If tokens(position) = "[" Then Return 0
            boundExpression &= tokens(position)
            position += 1
        Wend
        If position >= tokenCount OrElse tokens(position) <> "]" Then Return 0
        position += 1
        If boundExpression = "" Then
            If arrayRank <> 0 Then Return 0
            If sourceInitializer = "" Then
                isUnsizedArray = -1
                arrayRank = 1
                Return 0
            End If
            Dim hasInnerDimensions As Long = CInt( _
                position < tokenCount AndAlso tokens(position) = "[")
            If hasInnerDimensions <> 0 Then
                If CBodyExternalArrayInitializerCountFromText( _
                    translation, tokens(), tokenCount, position, sourceInitializer, _
                    arrayCount) = 0 OrElse _
                   arrayCount < 1 OrElse _
                   arrayCount > MAX_GENERIC_ARRAY_COUNT Then Return 0
                totalCount = arrayCount
                dimensions(0) = arrayCount
                arrayDimensions = Trim(Str(arrayCount)) & "ULL"
                arrayRank = 1
                Continue While
            End If
            Dim stringValues() As Long
            Dim stringValueCount As Long
            If ReadGenericStaticStringBytes( _
                sourceInitializer, stringValues(), stringValueCount) <> 0 Then
                If stringValueCount >= MAX_GENERIC_ARRAY_COUNT Then Return 0
                arrayCount = stringValueCount + 1
            ElseIf CBodyExternalArrayInitializerCountFromText( _
                translation, tokens(), tokenCount, position, sourceInitializer, _
                arrayCount) = 0 Then
                Return 0
            End If
            If arrayCount < 1 OrElse arrayCount > MAX_GENERIC_ARRAY_COUNT Then Return 0
            arrayRank = 1
            dimensions(0) = arrayCount
            arrayDimensions = Trim(Str(arrayCount)) & "ULL"
            Return -1
        End If

        Dim numericBoundExpression As String = boundExpression
        If translation.target.profile = C2FB_TARGET_GENERIC AndAlso _
           ReplaceGenericEnumNamesWithIntegerValues( _
                translation, boundExpression, numericBoundExpression) = 0 Then _
            Return 0
        Dim dimensionCount As Long
        If EvaluateSimpleArrayBound( _
            numericBoundExpression, dimensionCount, MAX_GENERIC_ARRAY_COUNT) = 0 Then _
            Return 0
        If totalCount > (MAX_GENERIC_ARRAY_COUNT \ dimensionCount) Then Return 0
        totalCount *= dimensionCount
        dimensions(arrayRank) = dimensionCount
        If arrayDimensions <> "" Then arrayDimensions &= ","
        arrayDimensions &= Trim(Str(dimensionCount)) & "ULL"
        arrayRank += 1
    Wend
    If arrayRank <= 0 OrElse totalCount < 1 OrElse _
       totalCount > MAX_GENERIC_ARRAY_COUNT Then Return 0
    If arrayRank > 1 AndAlso totalCount > MAX_SIMPLE_ARRAY_COUNT Then Return 0
    arrayCount = CLng(totalCount)
    Return -1
End Function

Private Function CBodySourceObjectInitializer( _
    ByVal declarationText As String, ByVal sourceName As String, _
    ByRef initializerText As String _
) As Long
    initializerText = ""
    Dim namePosition As Long = 0
    For scanPosition As Long = 1 To Len(declarationText) - Len(sourceName) + 1
        If Mid(declarationText, scanPosition, Len(sourceName)) <> sourceName Then _
            Continue For
        Dim beforeName As Long = 0
        Dim afterName As Long = 0
        If scanPosition > 1 Then beforeName = Asc(declarationText, scanPosition - 1)
        If scanPosition + Len(sourceName) <= Len(declarationText) Then _
            afterName = Asc(declarationText, scanPosition + Len(sourceName))
        If (beforeName <> 0 AndAlso IsIdentifierPart(beforeName) <> 0) OrElse _
           (afterName <> 0 AndAlso IsIdentifierPart(afterName) <> 0) Then _
            Continue For
        namePosition = scanPosition + Len(sourceName)
        Exit For
    Next
    If namePosition = 0 Then Return 0

    Dim parenthesisDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    Dim initializerStart As Long = 0
    For scanPosition As Long = namePosition To Len(declarationText) + 1
        Dim currentByte As Long = IIf( _
            scanPosition <= Len(declarationText), _
            Asc(declarationText, scanPosition), Asc(";"))
        If quoteByte <> 0 Then
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            Continue For
        End If
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quoteByte = currentByte
            Continue For
        End If
        Select Case currentByte
        Case Asc("("): parenthesisDepth += 1
        Case Asc(")"): If parenthesisDepth > 0 Then parenthesisDepth -= 1
        Case Asc("["): bracketDepth += 1
        Case Asc("]"): If bracketDepth > 0 Then bracketDepth -= 1
        Case Asc("{"): braceDepth += 1
        Case Asc("}"): If braceDepth > 0 Then braceDepth -= 1
        Case Asc("=")
            If initializerStart = 0 AndAlso parenthesisDepth = 0 AndAlso _
               bracketDepth = 0 AndAlso braceDepth = 0 Then _
                initializerStart = scanPosition + 1
        Case Asc(","), Asc(";")
            If initializerStart > 0 AndAlso parenthesisDepth = 0 AndAlso _
               bracketDepth = 0 AndAlso braceDepth = 0 Then
                initializerText = Trim(Mid( _
                    declarationText, initializerStart, _
                    scanPosition - initializerStart))
                Return IIf(initializerText <> "", -1, 0)
            End If
        End Select
    Next
    Return 0
End Function

Private Function CBodyCallbackArrayTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, tokens() As String, _
    ByVal tokenCount As Long, ByVal sourceName As String, _
    ByRef callbackResult As C2fbCallbackTypeResultModel _
) As Long
    If tokenCount < 1 OrElse tokenCount > UBound(tokens) + 1 Then Return 0
    Dim declaratorLastToken As Long = tokenCount - 1
    Dim assignmentToken As Long
    If FindC2fbTopLevelAssignmentToken( _
        tokens(), 0, declaratorLastToken, assignmentToken) = 0 Then Return 0
    If assignmentToken >= 0 Then declaratorLastToken = assignmentToken - 1
    If declaratorLastToken >= 0 AndAlso tokens(declaratorLastToken) = ";" Then _
        declaratorLastToken -= 1
    If declaratorLastToken < 0 Then Return 0

    Dim callbackTokens() As String
    ReDim callbackTokens(0 To declaratorLastToken)
    Dim callbackTokenCount As Long = 0
    Dim foundArray As Long = 0
    For tokenIndex As Long = 0 To declaratorLastToken
        If tokens(tokenIndex) = sourceName Then
            If tokenIndex + 1 > declaratorLastToken OrElse _
               tokens(tokenIndex + 1) <> "[" Then Return 0
            Dim suffixPosition As Long = tokenIndex + 1
            While suffixPosition <= declaratorLastToken AndAlso _
                  tokens(suffixPosition) = "["
                Dim nesting As Long = 0
                Dim closingBracket As Long = -1
                For scanIndex As Long = suffixPosition To declaratorLastToken
                    If tokens(scanIndex) = "[" Then
                        nesting += 1
                    ElseIf tokens(scanIndex) = "]" Then
                        nesting -= 1
                        If nesting = 0 Then
                            closingBracket = scanIndex
                            Exit For
                        End If
                    End If
                Next
                If closingBracket < 0 Then Return 0
                suffixPosition = closingBracket + 1
            Wend
            foundArray = -1
            ' Array dimensions are handled separately. Remove all suffixes so
            ' the callback resolver sees the element type.
            callbackTokens(callbackTokenCount) = tokens(tokenIndex)
            callbackTokenCount += 1
            tokenIndex = suffixPosition - 1
            Continue For
        End If
        callbackTokens(callbackTokenCount) = tokens(tokenIndex)
        callbackTokenCount += 1
    Next
    If foundArray = 0 OrElse callbackTokenCount <= 0 Then Return 0

    Dim arrayObjectNamePosition As Long = -1
    For tokenIndex As Long = 0 To callbackTokenCount - 1
        If callbackTokens(tokenIndex) = sourceName Then
            arrayObjectNamePosition = tokenIndex
            Exit For
        End If
    Next
    If arrayObjectNamePosition > 0 Then
        For typeTokenIndex As Long = 0 To arrayObjectNamePosition - 1
            For aliasIndex As Long = 0 To translation.body.aliasCount - 1
                With translation.body.aliases(aliasIndex)
                    If .name <> callbackTokens(typeTokenIndex) OrElse _
                       .callbackType = "" OrElse .ambiguous <> 0 OrElse _
                       CBodyCallbackIndexInContext( _
                           translation, .callbackType) < 0 Then Continue For
                    ' A callback typedef already includes the function-pointer
                    ' level; use it directly as the array element type.
                    callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED
                    callbackResult.callbackName = sourceName
                    callbackResult.freeBasicType = .callbackType
                    callbackResult.pointerDepth = 1
                    Return -1
                End With
            Next
        Next
    End If

    ResolveCBodyCallbackTypeInContext( _
        translation, catalog, callbackTokens(), 0, callbackTokenCount - 1, _
        callbackResult, 0, C2FB_TYPE_MAPPING_BODY)
    If callbackResult.status <> C2FB_CALLBACK_TYPE_CONVERTED OrElse _
       callbackResult.freeBasicType = "" OrElse _
       CBodyCallbackIndexInContext( _
           translation, callbackResult.freeBasicType) < 0 Then Return 0
    ' A typedef hides the callback declarator's object name. The array
    ' declarator above already verified that the selected object is an array.
    ' The resolved FreeBASIC callback alias describes the array element type.
    Return -1
End Function

Private Function CBodyCallbackArrayTargetMatchesInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal callbackType As String, ByVal functionName As String _
) As Long
    Dim callbackIndex As Long = _
        CBodyCallbackIndexInContext(translation, callbackType)
    If callbackIndex < 0 Then Return 0

    Dim procedureIndex As Long = CBodyProcedureIndex(translation, functionName)
    Dim functionReturnType As String
    Dim functionParameterCount As Long
    Dim functionIsVariadic As Long
    If procedureIndex >= 0 Then
        With translation.symbolTable.symbols(procedureIndex)
            If .ambiguous <> 0 OrElse .body.isAmbiguous <> 0 Then Return 0
            functionReturnType = .body.returnType
            functionParameterCount = .body.parameterCount
            functionIsVariadic = .body.isVariadic
        End With
    Else
        procedureIndex = FbBodyCallSignatureIndex(catalog, functionName)
        If procedureIndex < 0 Then Return 0
        With catalog.bodyCallSignatures(procedureIndex)
            If .parameterCount < 0 Then Return 0
            functionReturnType = .returnType
            functionParameterCount = .parameterCount
            functionIsVariadic = .isVariadic
        End With
    End If

    With translation.body.callbacks(callbackIndex)
        If .parameterCount <> functionParameterCount OrElse _
           .isVariadic <> functionIsVariadic Then Return 0
        If CBodyCallbackTypesCompatibleInContext( _
            translation, catalog, .returnType, functionReturnType, 0) = 0 Then _
            Return 0
        For parameterIndex As Long = 0 To .parameterCount - 1
            If CBodyCallbackTypesCompatibleInContext( _
                translation, catalog, _
                CBodyCallbackParameterTypeInContext( _
                    translation, .fbType, parameterIndex), _
                CBodyParameterType( _
                    translation, catalog, functionName, parameterIndex), 0) = 0 Then _
                Return 0
        Next
    End With
    Return -1
End Function

Private Function TranslateCBodyCallbackInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceText As String, ByVal callbackType As String, _
    ByRef initialValue As String _
) As Long
    initialValue = ""
    sourceText = GenericMacroStripOuterParentheses(Trim(sourceText))
    If sourceText = "" Then Return 0

    Dim elementTokens() As String
    Dim elementTokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceText, elementTokens(), elementTokenCount) = 0 Then Return 0
    Dim isNullPointerConstant As Long = CInt(LCase(sourceText) = "null") * -1
    If elementTokenCount = 1 AndAlso isNullPointerConstant = 0 Then
        Dim zeroValue As Long
        If EvaluateSimpleArrayBound( _
            sourceText, zeroValue, MAX_GENERIC_ARRAY_COUNT, -1) <> 0 AndAlso _
           zeroValue = 0 Then isNullPointerConstant = -1
    ElseIf elementTokenCount = 5 AndAlso _
           elementTokens(0) = "(" AndAlso _
           LCase(elementTokens(1)) = "void" AndAlso _
           elementTokens(2) = "*" AndAlso elementTokens(3) = ")" Then
        Dim castZeroValue As Long
        If EvaluateSimpleArrayBound( _
            elementTokens(4), castZeroValue, MAX_GENERIC_ARRAY_COUNT, -1) <> 0 AndAlso _
           castZeroValue = 0 Then isNullPointerConstant = -1
    End If
    If isNullPointerConstant <> 0 Then
        ' The destination field supplies the callback type. A generated alias
        ' may not be declared when an included record owns that field type.
        initialValue = "0"
        Return -1
    End If

    Dim functionName As String
    If elementTokenCount = 1 AndAlso _
       IsIdentifierToken(elementTokens(0)) <> 0 Then
        functionName = elementTokens(0)
    ElseIf elementTokenCount = 2 AndAlso elementTokens(0) = "&" AndAlso _
           IsIdentifierToken(elementTokens(1)) <> 0 Then
        functionName = elementTokens(1)
    Else
        Return 0
    End If
    If CBodyCallbackArrayTargetMatchesInContext( _
        translation, catalog, callbackType, functionName) = 0 Then Return 0
    Dim functionBindingName As String = CBodyCallName( _
        translation, catalog, functionName)
    Select Case functionName
    Case "memcmp", "memcpy", "memmove", "memset"
        ' FBC declares these C ABI procedures in crt/mem.bi. Refer to that
        ' declaration directly so source-unit translation does not depend on
        ' retaining a prototype from the included C string header.
        functionBindingName = functionName
    End Select
    initialValue = "ProcPtr(" & functionBindingName & ")"
    Return -1
End Function

Private Function TranslateCBodyStaticCallbackArrayInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceText As String, ByVal callbackType As String, _
    dimensions() As Long, ByVal arrayRank As Long, _
    ByVal arrayCount As Long, ByRef initialValue As String _
) As Long
    initialValue = ""
    If arrayRank < 1 OrElse arrayRank > MAX_GENERIC_ARRAY_RANK OrElse _
       arrayCount < 1 OrElse _
       arrayCount > MAX_GENERIC_STATIC_INITIALIZER_VALUES Then Return 0

    Dim sourceValues() As String
    ReDim sourceValues(0 To arrayCount - 1)
    Dim sourceValueCount As Long = 0
    If Trim(sourceText) <> "" Then
        If FlattenSimpleCArrayInitializer( _
            sourceText, dimensions(), arrayRank, 0, sourceValues(), _
            sourceValueCount, arrayCount, 0) = 0 OrElse _
           sourceValueCount <> arrayCount Then Return 0
    End If

    Dim translatedValues As String
    For elementIndex As Long = 0 To arrayCount - 1
        Dim sourceValue As String = sourceValues(elementIndex)
        If sourceValue = "" Then sourceValue = "0"
        Dim translatedValue As String
        If TranslateCBodyCallbackInitializer( _
            translation, catalog, sourceValue, callbackType, _
            translatedValue) = 0 Then Return 0
        If elementIndex > 0 Then translatedValues &= ", "
        translatedValues &= translatedValue
    Next
    initialValue = "{" & translatedValues & "}"
    Return -1
End Function

Private Function TranslateCBodyStaticRecordArrayInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceText As String, ByVal freeBasicType As String, _
    ByVal arrayCount As Long, ByRef initialValue As String _
) As Long
    sourceText = Trim(sourceText)
    If Left(sourceText, 1) <> "{" OrElse arrayCount <= 0 Then Return 0
    If CBodyRecordName(translation, catalog, freeBasicType) = "" Then Return 0

    Dim closingBrace As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceText, closingBrace, Asc("{"), Asc("}")) = 0 OrElse _
       Trim(Mid(sourceText, closingBrace)) <> "" Then Return 0
    Dim initializerBody As String = Trim(Mid( _
        sourceText, 2, closingBrace - 3))
    If initializerBody = "" Then Return 0
    If Right(initializerBody, 1) = "," Then _
        initializerBody = RTrim(Left( _
            initializerBody, Len(initializerBody) - 1))

    Dim values() As String
    Dim valueCount As Long
    If SplitSimpleCList( _
        initializerBody, values(), valueCount, 0, _
        MAX_GENERIC_STATIC_INITIALIZER_VALUES) = 0 OrElse _
       valueCount <= 0 OrElse valueCount > arrayCount Then Return 0

    Dim context As SimpleBodyContext
    Dim callableNames(0 To 0) As String
    Dim parameterNames(0 To 0) As String
    Dim parameterAliases(0 To 0) As String
    Dim parameterTypes(0 To 0) As String
    Dim translatedValues As String
    For valueIndex As Long = 0 To valueCount - 1
        Dim sourceValue As String = Trim(values(valueIndex))
        If Left(sourceValue, 1) <> "{" Then Return 0
        Dim translatedValue As String
        If TranslateSimpleRecordInitializer( _
            translation, catalog, sourceValue, freeBasicType, _
            translatedValue, context, callableNames(), 0, _
            parameterNames(), parameterAliases(), parameterTypes(), 0, -1) = 0 Then _
            Return 0
        If valueIndex > 0 Then translatedValues &= ", "
        translatedValues &= translatedValue
    Next
    initialValue = "{" & translatedValues & "}"
    Return -1
End Function

Private Function CBodyObjectVolatileMask( _
    itemTokens() As String, ByVal itemTokenCount As Long, _
    ByVal commonTypeTokenCount As Long, ByVal sourceName As String _
) As Long
    For tokenIndex As Long = commonTypeTokenCount To itemTokenCount - 1
        If itemTokens(tokenIndex) = sourceName Then
            Return C2fbVolatileQualifierMask( _
                itemTokens(), 0, tokenIndex - 1)
        End If
    Next
    Return 0
End Function

Private Sub RecordCBodyExternalObjectInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceName As String, ByVal cName As String, _
    ByVal freeBasicType As String, ByVal arrayCount As Long, _
    ByVal isArray As Long, ByVal isConst As Long, _
    ByVal isStatic As Long = 0, _
    ByVal initializerText As String = "", _
    ByVal isReused As Long = 0, _
    ByVal isUnsizedArray As Long = 0, _
    ByVal arrayRank As Long = 0, _
    ByVal arrayDimensions As String = "", _
    ByVal isDefinition As Long = 0, _
    ByVal pointerCount As Long = 0, _
    ByVal volatileMask As Long = 0 _
)
    If initializerText <> "" Then
        NormalizeGenericStaticInitializerValue(initializerText)
    End If

    For existingIndex As Long = 0 To translation.body.externalObjectCount - 1
        With translation.body.externalObjects(existingIndex)
            If .sourceName = sourceName Then
                If .cName <> cName OrElse .freeBasicType <> freeBasicType OrElse _
                   .isArray <> isArray OrElse _
                   .isConst <> isConst OrElse .isStatic <> isStatic OrElse _
                   .pointerCount <> pointerCount OrElse _
                   .volatileMask <> volatileMask OrElse _
                   .isReused <> isReused Then
                    .isAmbiguous = -1
                ElseIf .isDefinition <> 0 AndAlso isDefinition <> 0 AndAlso _
                       .initializerText <> initializerText Then
                    .isAmbiguous = -1
                ElseIf .arrayCount <> arrayCount OrElse _
                       .isUnsizedArray <> isUnsizedArray OrElse _
                       .arrayRank <> arrayRank OrElse _
                       .arrayDimensions <> arrayDimensions Then
                    If .isArray <> 0 AndAlso .isUnsizedArray <> 0 AndAlso _
                       isUnsizedArray = 0 AndAlso .arrayCount = 0 AndAlso _
                       arrayCount > 0 Then
                        ' An extern incomplete array may be completed by a
                        ' definition later in the same C translation unit.
                        .arrayCount = arrayCount
                        .isUnsizedArray = 0
                        .arrayRank = arrayRank
                        .arrayDimensions = arrayDimensions
                        .storageName = ""
                    ElseIf .isArray = 0 OrElse .isUnsizedArray <> 0 OrElse _
                           isUnsizedArray = 0 OrElse .arrayCount <= 0 OrElse _
                           arrayCount <> 0 Then
                        .isAmbiguous = -1
                    End If
                End If
                If .isAmbiguous = 0 AndAlso isDefinition <> 0 Then
                    If .isDefinition = 0 OrElse .initializerText = "" Then _
                        .initializerText = initializerText
                    .isDefinition = -1
                End If
                Exit Sub
            End If
        End With
    Next

    If translation.body.externalObjectCount >= MAX_BODY_EXTERNAL_OBJECTS Then _
        ReportError("translation unit exceeds the configured external-object limit")
    If translation.body.externalObjectCount > _
       UBound(translation.body.externalObjects) Then _
        ReDim Preserve translation.body.externalObjects( _
            0 To UBound(translation.body.externalObjects) * 2 + 1)

    Dim freeBasicName As String = _
        CBodyExternalObjectFreeBasicName(translation, catalog, sourceName)
    Dim storageName As String
    If isUnsizedArray <> 0 Then
        storageName = freeBasicName & "_storage"
        Do While CBodyExternalObjectNameConflict( _
            translation, catalog, storageName) <> 0
            storageName &= "_"
        Loop
    End If
    With translation.body.externalObjects(translation.body.externalObjectCount)
        .sourceName = sourceName
        .cName = cName
        .freeBasicName = freeBasicName
        .storageName = storageName
        .freeBasicType = freeBasicType
        .initializerText = initializerText
        .pointerCount = pointerCount
        .volatileMask = volatileMask
        .arrayCount = arrayCount
        .arrayRank = arrayRank
        .arrayDimensions = arrayDimensions
        .isArray = isArray
        .isUnsizedArray = isUnsizedArray
        .isConst = isConst
        .isStatic = isStatic
        .isDefinition = isDefinition
        .isReused = isReused
    End With
    translation.body.externalObjectCount += 1
End Sub

Private Function TranslateCBodyMultidimensionalStaticArrayInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByVal freeBasicType As String, _
    dimensions() As Long, ByVal arrayRank As Long, _
    ByVal arrayCount As Long, ByVal isPointerLike As Long, _
    ByRef initialValue As String _
) As Long
    initialValue = ""
    If sourceText = "" Then Return -1
    If arrayRank < 2 OrElse arrayRank > MAX_GENERIC_ARRAY_RANK OrElse _
       arrayCount < 1 OrElse arrayCount > MAX_SIMPLE_ARRAY_COUNT Then Return 0

    Dim values() As String
    ReDim values(0 To arrayCount - 1)
    Dim valueCount As Long = 0
    If FlattenSimpleCArrayInitializer( _
        sourceText, dimensions(), arrayRank, 0, values(), valueCount, _
        arrayCount, 0) = 0 OrElse valueCount <> arrayCount Then Return 0

    Dim translatedValues As String
    For valueIndex As Long = 0 To valueCount - 1
        Dim sourceValue As String = values(valueIndex)
        If sourceValue = "" Then sourceValue = "0"
        Dim scalarArrayCount As Long = 0
        Dim translatedValue As String
        If TranslateGenericModuleStaticInitializer( _
            translation, sourceValue, freeBasicType, 0, isPointerLike, _
            0, 0, 0, 0, scalarArrayCount, translatedValue, "") = 0 Then Return 0
        If valueIndex > 0 Then translatedValues &= ", "
        translatedValues &= translatedValue
    Next
    initialValue = "{" & translatedValues & "}"
    Return -1
End Function

Private Function CBodyBuiltinCallTarget( _
    ByVal procedureName As String _
) As String
    ' GCC memory builtins map to their C library calls. glibc's signbit
    ' builtins map to math entrypoints with matching C signatures.
    Select Case procedureName
    Case "__builtin_memcpy": Return "memcpy"
    Case "__builtin_memmove": Return "memmove"
    Case "__builtin_memset": Return "memset"
    Case "__builtin_signbit": Return "__signbit"
    Case "__builtin_signbitf": Return "__signbitf"
    Case "__builtin_signbitl": Return "__signbitl"
    End Select
    Return ""
End Function

Private Function CBodyReturnType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal procedureName As String _
) As String
    Dim lookupName As String = CBodyBuiltinCallTarget(procedureName)
    If lookupName = "" Then lookupName = procedureName
    If LCase(procedureName) = "abs" OrElse LCase(procedureName) = "abs_" Then _
        Print "CBodyCallName abs: "; procedureName; " lookup="; lookupName
    Dim index As Long = CBodyProcedureIndex(translation, lookupName)
    If index >= 0 AndAlso translation.symbolTable.symbols(index).ambiguous = 0 AndAlso _
       translation.symbolTable.symbols(index).body.isAmbiguous = 0 Then _
        Return translation.symbolTable.symbols(index).body.returnType
    index = FbBodyCallSignatureIndex(catalog, lookupName)
    If index < 0 OrElse catalog.bodyCallSignatures(index).parameterCount < 0 Then Return ""
    Return catalog.bodyCallSignatures(index).returnType
End Function

Private Function CBodyParameterType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal procedureName As String, ByVal parameterIndex As Long _
) As String
    Dim lookupName As String = CBodyBuiltinCallTarget(procedureName)
    If lookupName = "" Then lookupName = procedureName
    Dim index As Long = CBodyProcedureIndex(translation, lookupName)
    Dim parameterTypes As String
    Dim parameterCount As Long
    If index >= 0 AndAlso translation.symbolTable.symbols(index).ambiguous = 0 AndAlso _
       translation.symbolTable.symbols(index).body.isAmbiguous = 0 Then
        parameterTypes = translation.symbolTable.symbols(index).body.parameterTypes
        parameterCount = translation.symbolTable.symbols(index).body.parameterCount
    Else
        index = FbBodyCallSignatureIndex(catalog, lookupName)
        If index < 0 OrElse catalog.bodyCallSignatures(index).parameterCount < 0 Then Return ""
        parameterTypes = catalog.bodyCallSignatures(index).parameterTypes
        parameterCount = catalog.bodyCallSignatures(index).parameterCount
    End If
    If parameterIndex < 0 OrElse parameterIndex >= parameterCount Then Return ""
    Dim start As Long = 1
    For i As Long = 0 To parameterIndex - 1
        start = InStr(start, parameterTypes, "|") + 1
        If start <= 1 Then Return ""
    Next
    Dim finish As Long = InStr(start, parameterTypes, "|")
    If finish = 0 Then Return ""
    Return Mid(parameterTypes, start, finish - start)
End Function

Private Function ResolveCBodyFunctionTypedefCallback( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, tokens() As String, _
    ByVal tokenCount As Long, ByRef aliasName As String, _
    ByRef callbackType As String _
) As Long
    aliasName = ""
    callbackType = ""
    If tokenCount < 5 OrElse tokens(0) <> "typedef" Then Return 0
    Dim lastToken As Long = tokenCount - 1
    If tokens(lastToken) = ";" Then lastToken -= 1
    If lastToken < 4 Then Return 0

    For candidateToken As Long = 2 To lastToken - 2
        Dim nameToken As Long = candidateToken
        Dim parameterOpen As Long
        Dim prefixEnd As Long = candidateToken - 1
        If tokens(candidateToken) = "(" AndAlso _
           candidateToken + 3 <= lastToken AndAlso _
           IsIdentifierToken(tokens(candidateToken + 1)) <> 0 AndAlso _
           tokens(candidateToken + 2) = ")" AndAlso _
           tokens(candidateToken + 3) = "(" Then
            nameToken = candidateToken + 1
            parameterOpen = candidateToken + 3
        ElseIf IsIdentifierToken(tokens(candidateToken)) <> 0 AndAlso _
               tokens(candidateToken + 1) = "(" Then
            parameterOpen = candidateToken + 1
        Else
            Continue For
        End If
        Dim parameterGroupEnd As Long = parameterOpen
        If SkipCDeclaratorGroup( _
            tokens(), parameterGroupEnd, lastToken, "(", ")") = 0 OrElse _
           parameterGroupEnd <> lastToken + 1 Then Continue For

        Dim callbackTokens() As String
        ReDim callbackTokens(0 To lastToken + 2)
        Dim callbackTokenCount As Long = 0
        For tokenIndex As Long = 1 To prefixEnd
            callbackTokens(callbackTokenCount) = tokens(tokenIndex)
            callbackTokenCount += 1
        Next
        callbackTokens(callbackTokenCount) = "("
        callbackTokenCount += 1
        callbackTokens(callbackTokenCount) = "*"
        callbackTokenCount += 1
        callbackTokens(callbackTokenCount) = tokens(nameToken)
        callbackTokenCount += 1
        callbackTokens(callbackTokenCount) = ")"
        callbackTokenCount += 1
        For tokenIndex As Long = parameterOpen To lastToken
            callbackTokens(callbackTokenCount) = tokens(tokenIndex)
            callbackTokenCount += 1
        Next

        Dim callbackResult As C2fbCallbackTypeResultModel
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, callbackTokens(), 0, _
            callbackTokenCount - 1, callbackResult, 0, C2FB_TYPE_MAPPING_BODY)
        If callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED AndAlso _
           callbackResult.freeBasicType <> "" Then
            aliasName = tokens(nameToken)
            callbackType = callbackResult.freeBasicType
            Dim mappedCallbackType As String = _
                MappedFbBodyTypeAlias(translation, catalog, aliasName)
            If mappedCallbackType <> "" AndAlso _
               CBodyCallbackTypesCompatibleInContext( _
                   translation, catalog, callbackType, mappedCallbackType, 0) <> 0 Then _
                callbackType = mappedCallbackType
            Return -1
        End If
    Next
    Return 0
End Function

Private Sub RecordCBodyTypeAlias( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef declaration As C2fbDeclarationModel _
)
    Dim tokenCount As Long = declaration.tokenCount
    If tokenCount < 3 OrElse tokenCount >= MAX_TYPE_WORDS Then Exit Sub
    Dim tokens() As String
    ReDim tokens(0 To tokenCount - 1)
    For tokenIndex As Long = 0 To tokenCount - 1
        tokens(tokenIndex) = declaration.tokens(tokenIndex)
    Next
    If tokens(0) <> "typedef" Then Exit Sub
    Dim callbackResult As C2fbCallbackTypeResultModel
    ResolveCBodyCallbackTypeInContext( _
        translation, catalog, tokens(), 1, tokenCount - 1, callbackResult, 0, _
        C2FB_TYPE_MAPPING_BODY)
    Dim functionTypeAliasName As String
    Dim functionTypeAlias As String
    Dim isFunctionTypeAlias As Long = ResolveCBodyFunctionTypedefCallback( _
        translation, catalog, tokens(), tokenCount, _
        functionTypeAliasName, functionTypeAlias)
    If callbackResult.status = C2FB_CALLBACK_TYPE_UNSUPPORTED AndAlso _
       isFunctionTypeAlias = 0 Then Exit Sub
    If callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED AndAlso _
       callbackResult.callbackName <> "" Then
        For i As Long = 0 To translation.body.aliasCount - 1
            If translation.body.aliases(i).name = callbackResult.callbackName Then
                If translation.body.aliases(i).callbackType <> callbackResult.freeBasicType Then translation.body.aliases(i).ambiguous = -1
                Exit Sub
            End If
        Next
        If translation.body.aliasCount >= MAX_C2FB_BODY_TYPE_ALIASES Then _
            ReportError("source exceeds the configured typedef limit")
        If translation.body.aliasCount > UBound(translation.body.aliases) Then ReDim Preserve translation.body.aliases(0 To UBound(translation.body.aliases) * 2 + 1)
        translation.body.aliases(translation.body.aliasCount).name = callbackResult.callbackName
        translation.body.aliases(translation.body.aliasCount).baseType = callbackResult.freeBasicType
        translation.body.aliases(translation.body.aliasCount).callbackType = callbackResult.freeBasicType
        translation.body.aliasCount += 1
        Exit Sub
    End If

    If isFunctionTypeAlias <> 0 Then
        For aliasIndex As Long = 0 To translation.body.aliasCount - 1
            If translation.body.aliases(aliasIndex).name = functionTypeAliasName Then
                If translation.body.aliases(aliasIndex).callbackType <> functionTypeAlias Then _
                    translation.body.aliases(aliasIndex).ambiguous = -1
                Exit Sub
            End If
        Next
        If translation.body.aliasCount >= MAX_C2FB_BODY_TYPE_ALIASES Then _
            ReportError("source exceeds the configured typedef limit")
        If translation.body.aliasCount > UBound(translation.body.aliases) Then _
            ReDim Preserve translation.body.aliases( _
                0 To UBound(translation.body.aliases) * 2 + 1)
        With translation.body.aliases(translation.body.aliasCount)
            .name = functionTypeAliasName
            .baseType = functionTypeAlias
            .callbackType = functionTypeAlias
            ' C function typedefs decay to procedure pointers when used as values.
            .pointerCount = -1
        End With
        translation.body.aliasCount += 1
        Exit Sub
    End If

    ' Array typedefs decay to element pointers in C parameter lists. Keep
    ' their extent for sizeof(type) and parameter lowering, but do not map
    ' them as scalar aliases elsewhere in a function body.
    Dim arrayOpen As Long = -1
    Dim arrayAliasName As String = ""
    For tokenIndex As Long = 2 To tokenCount - 2
        If tokens(tokenIndex) = "[" AndAlso _
           IsIdentifierToken(tokens(tokenIndex - 1)) <> 0 Then
            arrayOpen = tokenIndex
            arrayAliasName = tokens(tokenIndex - 1)
            Exit For
        End If
    Next
    If arrayOpen > 2 AndAlso arrayAliasName <> "" Then
        Dim arrayClose As Long = -1
        Dim bracketDepth As Long = 0
        For tokenIndex As Long = arrayOpen To tokenCount - 1
            If tokens(tokenIndex) = "[" Then bracketDepth += 1
            If tokens(tokenIndex) = "]" Then
                bracketDepth -= 1
                If bracketDepth = 0 Then
                    arrayClose = tokenIndex
                    Exit For
                End If
            End If
        Next
        If arrayClose = tokenCount - 1 Then
            Dim boundExpression As String = ""
            For tokenIndex As Long = arrayOpen + 1 To arrayClose - 1
                boundExpression &= tokens(tokenIndex)
            Next
            Dim arrayCount As Long
            If boundExpression <> "" AndAlso _
               EvaluateSimpleArrayBound(boundExpression, arrayCount) <> 0 Then
                Dim elementTokens() As String
                ReDim elementTokens(0 To arrayOpen - 3)
                For tokenIndex As Long = 1 To arrayOpen - 2
                    elementTokens(tokenIndex - 1) = tokens(tokenIndex)
                Next
                Dim resolvedArrayElement As C2fbResolvedTypeModel
                ResolveC2fbTypeModel( _
                    translation, catalog, elementTokens(), 0, arrayOpen - 3, _
                    resolvedArrayElement)
                If resolvedArrayElement.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Exit Sub
                Dim elementType As String = resolvedArrayElement.freeBasicType
                If elementType <> "" AndAlso elementType <> "void" Then
                    For aliasIndex As Long = 0 To translation.body.aliasCount - 1
                        If translation.body.aliases(aliasIndex).name = arrayAliasName Then
                            With translation.body.aliases(aliasIndex)
                                If .isArray = 0 OrElse .arrayElementType <> elementType OrElse _
                                   .arrayCount <> arrayCount Then .ambiguous = -1
                            End With
                            Exit Sub
                        End If
                    Next
                    If translation.body.aliasCount >= _
                       MAX_C2FB_BODY_TYPE_ALIASES Then _
                        ReportError("source exceeds the configured typedef limit")
                    If translation.body.aliasCount > UBound(translation.body.aliases) Then _
                        ReDim Preserve translation.body.aliases( _
                            0 To UBound(translation.body.aliases) * 2 + 1)
                    With translation.body.aliases(translation.body.aliasCount)
                        .name = arrayAliasName
                        .arrayElementType = elementType
                        .arrayCount = arrayCount
                        .isArray = -1
                        .isConst = resolvedArrayElement.isConst
                    End With
                    translation.body.aliasCount += 1
                End If
            End If
        End If
        Exit Sub
    End If

    Dim aliasName As String = tokens(tokenCount - 1)
    If IsIdentifierToken(aliasName) = 0 Then Exit Sub
    Dim resolvedAliasType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        translation, catalog, tokens(), 1, tokenCount - 2, resolvedAliasType, _
        C2FB_POINTER_MAPPING_PRESERVE, C2FB_TYPE_MAPPING_BODY, _
        C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
    If resolvedAliasType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Exit Sub
    Dim pointerCount As Long = resolvedAliasType.pointerCount
    Dim isConst As Long = resolvedAliasType.isConst
    Dim baseType As String = resolvedAliasType.freeBasicType
    If Len(baseType) = 0 OrElse _
       (baseType = "void" AndAlso pointerCount <> 0) Then Exit Sub
    For i As Long = 1 To pointerCount
        If Right(baseType, 4) <> " Ptr" Then Exit Sub
        baseType = Left(baseType, Len(baseType) - 4)
    Next
    If Left(baseType, 6) = "Const " Then baseType = Mid(baseType, 7)
    For i As Long = 0 To translation.body.aliasCount - 1
        If translation.body.aliases(i).name = aliasName Then
            If translation.body.aliases(i).baseType <> baseType OrElse _
               translation.body.aliases(i).pointerCount <> pointerCount OrElse _
               translation.body.aliases(i).isConst <> isConst Then translation.body.aliases(i).ambiguous = -1
            Exit Sub
        End If
    Next
    If translation.body.aliasCount >= MAX_C2FB_BODY_TYPE_ALIASES Then _
        ReportError("source exceeds the configured typedef limit")
    If translation.body.aliasCount > UBound(translation.body.aliases) Then ReDim Preserve translation.body.aliases(0 To UBound(translation.body.aliases) * 2 + 1)
    With translation.body.aliases(translation.body.aliasCount)
        .name = aliasName
        .baseType = baseType
        .pointerCount = pointerCount
        .isConst = isConst
    End With
    translation.body.aliasCount += 1
End Sub

Private Sub RecordCBodyRecordTypedefAlias( _
    ByRef translation As C2fbTranslationContext, _
    ByVal aliasName As String, ByVal recordTag As String, _
    ByVal pointerCount As Long = 0 _
)
    If aliasName = "" OrElse recordTag = "" OrElse aliasName = recordTag Then Exit Sub
    For aliasIndex As Long = 0 To translation.body.aliasCount - 1
        With translation.body.aliases(aliasIndex)
            If .name <> aliasName Then Continue For
            If .baseType <> recordTag OrElse .pointerCount <> pointerCount OrElse _
               .isArray <> 0 Then .ambiguous = -1
            Exit Sub
        End With
    Next
    If translation.body.aliasCount >= MAX_C2FB_BODY_TYPE_ALIASES Then _
        ReportError("source exceeds the configured typedef limit")
    If translation.body.aliasCount > UBound(translation.body.aliases) Then _
        ReDim Preserve translation.body.aliases( _
            0 To UBound(translation.body.aliases) * 2 + 1)
    With translation.body.aliases(translation.body.aliasCount)
        .name = aliasName
        .baseType = recordTag
        .pointerCount = pointerCount
    End With
    translation.body.aliasCount += 1
End Sub

Private Function CBodyParameterHasEnumSpecifier( _
    tokens() As String, ByVal startToken As Long, ByVal endToken As Long _
) As Long
    If startToken < 0 OrElse endToken < startToken Then Return 0
    For tokenIndex As Long = startToken To endToken
        If tokens(tokenIndex) = "enum" Then Return -1
    Next
    Return 0
End Function

Private Function CBodyResolveUnnamedEnumParameter( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, tokens() As String, _
    ByVal startToken As Long, ByVal endToken As Long, _
    ByVal argumentNumber As Long, _
    ByRef result As C2fbParameterConversionResultModel _
) As Long
    If CBodyParameterHasEnumSpecifier( _
        tokens(), startToken, endToken) = 0 Then Return 0

    ' This fallback only handles scalar and pointer enum types. Function
    ' pointers and array declarators need their dedicated parameter lowering.
    For tokenIndex As Long = startToken To endToken
        If tokens(tokenIndex) = "(" OrElse tokens(tokenIndex) = "[" Then _
            Return 0
    Next

    Dim resolvedType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        translation, catalog, tokens(), startToken, endToken, resolvedType, _
        C2FB_POINTER_MAPPING_PRESERVE, C2FB_TYPE_MAPPING_BODY)
    If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0

    result.status = C2FB_PARAMETER_CONVERSION_CONVERTED
    result.sourceName = "arg" & Trim(Str(argumentNumber))
    result.argumentName = result.sourceName
    result.freeBasicType = resolvedType.freeBasicType
    result.freeBasicDeclaration = "ByVal " & result.sourceName & " As " & _
        resolvedType.freeBasicType
    result.defaultValue = ""
    result.isByRef = 0
    Return -1
End Function

Private Sub RecordCBodyProcedure( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef declaration As C2fbDeclarationModel _
)
    If declaration.entryKind <> C2FB_DECLARATION_FUNCTION OrElse _
       declaration.unsupportedAssemblyName <> 0 OrElse _
       declaration.tokenCount = 0 OrElse declaration.isConditional <> 0 Then Exit Sub
    Dim tokenCount As Long = declaration.tokenCount
    Dim tokens() As String
    ReDim tokens(0 To declaration.tokenCount - 1)
    For tokenIndex As Long = 0 To declaration.tokenCount - 1
        tokens(tokenIndex) = declaration.tokens(tokenIndex)
    Next
    Dim functionDeclaration As C2fbFunctionDeclarationModel = _
        declaration.functionDeclaration
    Dim procedureName As String = declaration.sourceName
    Dim linkName As String = declaration.linkName
    Dim callingConvention As String = CFunctionCallingConvention( _
        declaration.text, procedureName, C2FB_TYPE_MAPPING_GENERIC_HEADER)
    Dim isNoReturn As Long = declaration.isNoReturn
    Dim opening As Long = functionDeclaration.declarator.firstFunctionOpenToken
    Dim declaratorStart As Long = functionDeclaration.declaratorStartToken
    Dim bindingOrder As String = functionDeclaration.declarator.bindingOrder
    Dim closingPosition As Long = opening
    If SkipCDeclaratorGroup(tokens(), closingPosition, tokenCount - 1, "(", ")") = 0 Then Exit Sub
    Dim closing As Long = closingPosition - 1

    Dim returnStart As Long = 0
    Dim isStatic As Long = 0
    While returnStart < declaratorStart
        Select Case tokens(returnStart)
        Case "static": isStatic = -1
        Case "extern", "inline", "__inline", "__inline__", _
             "_Noreturn", "__noreturn", _
             "__extension__", "register", "SQLITE_API", "SQLITE_PRIVATE":
        Case Else: Exit While
        End Select
        returnStart += 1
    Wend

    Dim pointerCount As Long = 0
    Dim functionPointerReturn As Long = 0
    For bindingIndex As Long = 2 To Len(bindingOrder)
        Select Case Mid(bindingOrder, bindingIndex, 1)
        Case "P": pointerCount += 1
        Case "F": functionPointerReturn = -1
        Case "A": Exit Sub
        End Select
    Next

    Dim returnType As String
    If functionPointerReturn <> 0 Then
        If pointerCount = 0 Then Exit Sub
        returnType = "Any"
        For pointerIndex As Long = 1 To pointerCount
            returnType &= " Ptr"
        Next
    Else
        Dim returnTypeTokens() As String
        ReDim returnTypeTokens(0 To 31)
        Dim returnTokenCount As Long = 0
        For tokenIndex As Long = returnStart To declaratorStart - 1
            AddToken(returnTypeTokens(), returnTokenCount, tokens(tokenIndex))
        Next
        For pointerIndex As Long = 1 To pointerCount
            AddToken(returnTypeTokens(), returnTokenCount, "*")
        Next
        Dim resolvedReturnType As C2fbResolvedTypeModel
        ResolveC2fbTypeModel(translation, catalog, _
            returnTypeTokens(), 0, returnTokenCount - 1, resolvedReturnType)
        If resolvedReturnType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Exit Sub
        returnType = resolvedReturnType.freeBasicType
        pointerCount = resolvedReturnType.pointerCount
        If pointerCount = 0 AndAlso _
           C2fbTypeRecognitionStatusInContext( _
               translation, catalog, returnTypeTokens(), 0, _
               returnTokenCount - 1) <> C2FB_TYPE_RESOLUTION_RESOLVED Then Exit Sub
    End If

    Dim parameterTypes As String
    Dim parameterCount As Long = 0
    Dim isVariadic As Long = 0
    Dim depth As Long = 0
    Dim start As Long = opening + 1
    Dim foundEnd As Long = 0
    For i As Long = start To closing
        If tokens(i) = "(" Then depth += 1
        Dim atEnd As Long = CInt(tokens(i) = ")" AndAlso depth = 0)
        If tokens(i) = ")" AndAlso depth > 0 Then
            depth -= 1
            Continue For
        End If
        If atEnd <> 0 OrElse (tokens(i) = "," AndAlso depth = 0) Then
            If i = start + 1 AndAlso tokens(start) = "..." Then
                isVariadic = -1
            Else
                Dim parameterResult As C2fbParameterConversionResultModel
                ConvertParameterInContext( _
                    translation, catalog, tokens(), start, i - 1, _
                    parameterCount, parameterResult)
                If parameterResult.status = C2FB_PARAMETER_CONVERSION_UNSUPPORTED OrElse _
                   parameterResult.status = C2FB_PARAMETER_CONVERSION_INVALID Then
                    If CBodyResolveUnnamedEnumParameter( _
                        translation, catalog, tokens(), start, i - 1, _
                        parameterCount, parameterResult) = 0 Then Exit Sub
                ElseIf parameterResult.status = C2FB_PARAMETER_CONVERSION_VARIADIC Then
                    Exit Sub
                End If
                If parameterResult.status = C2FB_PARAMETER_CONVERSION_CONVERTED Then
                    Dim parameterName As String = parameterResult.sourceName
                    Dim typeEnd As Long = i - 1
                    If tokens(typeEnd) = parameterName Then typeEnd -= 1
                    Dim resolvedParameterType As C2fbResolvedTypeModel
                    Dim arrayTypedefType As String = _
                        CBodyArrayTypedefParameterTypeInContext( _
                            translation, tokens(), start, typeEnd)
                    Dim pointerArrayElementType As String
                    Dim pointerArrayElementCount As Long
                    Dim pointerArrayElementIsConst As Long
                    If CBodyPointerToArrayTypedefParameterInContext( _
                        translation, tokens(), start, typeEnd, _
                        pointerArrayElementType, pointerArrayElementCount, _
                        pointerArrayElementIsConst) <> 0 Then
                        RecordCBodyPointerToArrayParameterInContext( _
                            translation, procedureName, parameterCount, _
                            parameterName, _
                            pointerArrayElementType, pointerArrayElementCount, _
                            pointerArrayElementIsConst)
                    ElseIf declaration.isFunctionDefinition <> 0 AndAlso _
                        CBodyDirectPointerToArrayParameterInContext( _
                            translation, tokens(), start, i - 1, parameterName, _
                            parameterResult.freeBasicType, pointerArrayElementType, _
                            pointerArrayElementCount, pointerArrayElementIsConst) <> 0 Then
                        RecordCBodyPointerToArrayParameterInContext( _
                            translation, procedureName, parameterCount, _
                            parameterName, pointerArrayElementType, _
                            pointerArrayElementCount, pointerArrayElementIsConst)
                    End If
                    If arrayTypedefType <> "" AndAlso _
                       arrayTypedefType = parameterResult.freeBasicType Then
                        ' ConvertParameterInContext already adjusted this C
                        ' array typedef parameter to its element pointer. The
                        ' ordinary type resolver sees the typedef's storage
                        ' array, so reusing its result would hide the callable
                        ' procedure from body-expression parsing.
                        resolvedParameterType.status = _
                            C2FB_TYPE_RESOLUTION_RESOLVED
                        resolvedParameterType.freeBasicType = arrayTypedefType
                    ElseIf IsCBodyCallbackTypeInContext( _
                        translation, parameterResult.freeBasicType) <> 0 Then
                        ' Callback declarators have already been checked by
                        ' ConvertParameterInContext. The ordinary type parser
                        ' cannot resolve their nested function declarator.
                        resolvedParameterType.status = _
                            C2FB_TYPE_RESOLUTION_RESOLVED
                        resolvedParameterType.freeBasicType = _
                            parameterResult.freeBasicType
                    ElseIf CBodyParameterHasEnumSpecifier( _
                        tokens(), start, typeEnd) <> 0 Then
                        ' ConvertParameterInContext has already resolved this
                        ' enum tag. The known-types-only resolver below accepts
                        ' typedef names but can reject the same bare enum tag.
                        resolvedParameterType.status = _
                            C2FB_TYPE_RESOLUTION_RESOLVED
                        resolvedParameterType.freeBasicType = _
                            parameterResult.freeBasicType
                    ElseIf InStr(parameterResult.freeBasicType, " Ptr") = 0 Then
                        ResolveC2fbTypeModel( _
                            translation, catalog, tokens(), start, typeEnd, _
                            resolvedParameterType, C2FB_POINTER_MAPPING_PRESERVE, _
                            C2FB_TYPE_MAPPING_BODY, C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
                    Else
                        ResolveC2fbTypeModel( _
                            translation, catalog, tokens(), start, typeEnd, resolvedParameterType)
                    End If
                    If resolvedParameterType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Exit Sub
                    Dim recordedType As String = parameterResult.freeBasicType
                    If resolvedParameterType.isConst <> 0 AndAlso _
                       Left(recordedType, 3) = "Any" Then recordedType = "Const " & recordedType
                    parameterTypes &= recordedType & "|"
                    parameterCount += 1
                End If
            End If
            start = i + 1
            If atEnd <> 0 Then
                foundEnd = -1
                Exit For
            End If
        End If
    Next
    If foundEnd = 0 Then Exit Sub
    Dim symbolKind As C2fbSymbolKind = GENERIC_SYMBOL_FUNCTION
    If returnType = "void" Then symbolKind = GENERIC_SYMBOL_SUB
    Dim freeBasicName As String = CBodyFreeBasicProcedureNameInContext( _
        translation, catalog, procedureName)
    Dim index As Long = EnsureC2fbSymbolInContext( _
        translation, procedureName, procedureName, freeBasicName, symbolKind)
    If index < 0 Then ReportError("source exceeds the configured procedure limit")
    If translation.symbolTable.symbols(index).body.isDeclared = 0 Then
        translation.symbolTable.symbols(index).body.returnType = returnType
        translation.symbolTable.symbols(index).body.parameterTypes = parameterTypes
        translation.symbolTable.symbols(index).body.parameterCount = parameterCount
        translation.symbolTable.symbols(index).body.isVariadic = isVariadic
        translation.symbolTable.symbols(index).body.isStatic = isStatic
        translation.symbolTable.symbols(index).body.linkName = linkName
        translation.symbolTable.symbols(index).body.callingConvention = _
            callingConvention
    ElseIf translation.symbolTable.symbols(index).body.returnType <> returnType OrElse _
           translation.symbolTable.symbols(index).body.parameterTypes <> parameterTypes OrElse _
           translation.symbolTable.symbols(index).body.isVariadic <> isVariadic OrElse _
           translation.symbolTable.symbols(index).body.callingConvention <> callingConvention Then
        translation.symbolTable.symbols(index).body.isAmbiguous = -1
    ElseIf linkName <> "" Then
        If translation.symbolTable.symbols(index).body.linkName <> "" AndAlso _
           translation.symbolTable.symbols(index).body.linkName <> linkName Then
            translation.symbolTable.symbols(index).body.isAmbiguous = -1
        Else
            translation.symbolTable.symbols(index).body.linkName = linkName
        End If
    End If
    translation.symbolTable.symbols(index).body.isDeclared = -1
    If isNoReturn <> 0 Then _
        translation.symbolTable.symbols(index).body.isNoReturn = -1
    If declaration.isFunctionDefinition <> 0 Then _
        translation.symbolTable.symbols(index).body.hasDefinition = -1
    If declaration.isFunctionDefinition <> 0 AndAlso _
       declaration.isHeaderBody <> 0 AndAlso isStatic = 0 Then
        Dim hasExternSpecifier As Long = 0
        Dim hasInlineSpecifier As Long = 0
        For tokenIndex As Long = 0 To _
            declaration.functionDeclaration.declaratorStartToken - 1
            Select Case declaration.tokens(tokenIndex)
            Case "extern": hasExternSpecifier = -1
            Case "inline", "__inline", "__inline__": hasInlineSpecifier = -1
            End Select
        Next
        If hasExternSpecifier <> 0 AndAlso hasInlineSpecifier <> 0 Then _
            translation.symbolTable.symbols(index).body.isExternal = -1
    End If
    If isStatic <> 0 Then translation.symbolTable.symbols(index).body.isStatic = -1
End Sub

Private Function CBodyFreeBasicProcedureNameInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As String
    Dim existingIndex As Long = _
        C2fbSymbolIndexInContext(translation, sourceName)
    If existingIndex >= 0 AndAlso _
       translation.symbolTable.symbols(existingIndex).body.isDeclared <> 0 AndAlso _
       translation.symbolTable.symbols(existingIndex).freeBasicName <> "" Then _
        Return translation.symbolTable.symbols(existingIndex).freeBasicName

    Dim result As String = _
        GenericProcedureRenameInPolicy(translation.genericC.policy, sourceName)
    If result = "" Then result = sourceName
    If C2fbFreeBasicIdentifierIsKeyword(result) <> 0 Then
        result &= "_"
        Do While CBodyExternalObjectNameConflict( _
            translation, catalog, result) <> 0
            result &= "_"
        Loop
    End If
    Return result
End Function

Private Function CBodySymbolFreeBasicName( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal symbolIndex As Long _
) As String
    If symbolIndex < 0 OrElse symbolIndex >= translation.symbolTable.symbolCount Then Return ""
    Dim renamedName As String
    Select Case translation.symbolTable.symbols(symbolIndex).kind
    Case GENERIC_SYMBOL_FUNCTION, GENERIC_SYMBOL_SUB
        renamedName = GenericProcedureRenameInPolicy( _
            translation.genericC.policy, _
            translation.symbolTable.symbols(symbolIndex).sourceName)
    Case Else
        renamedName = GenericSymbolRenameInPolicy( _
            translation.genericC.policy, _
            translation.symbolTable.symbols(symbolIndex).sourceName)
    End Select
    If renamedName <> "" Then
        If C2fbFreeBasicIdentifierIsKeyword(renamedName) <> 0 Then _
            renamedName &= "_"
        Return renamedName
    End If
    If translation.symbolTable.symbols(symbolIndex).body.callNameOverride <> "" Then _
        Return translation.symbolTable.symbols(symbolIndex).body.callNameOverride
    Dim result As String = _
        translation.symbolTable.symbols(symbolIndex).freeBasicName
    If C2fbFreeBasicIdentifierIsKeyword(result) <> 0 Then _
        Return CBodyFreeBasicProcedureNameInContext( _
            translation, catalog, result)
    Return result
End Function

Private Function IsCBodyRuntimeProcedure(ByVal procedureName As String) As Long
    ' These standard C procedures have host C declarations in the input and
    ' are provided by the C runtime linked by FreeBASIC. Alias their BASIC
    ' names so procedures such as abs cannot select a BASIC intrinsic.
    Select Case procedureName
    Case "memcpy", "memmove", "memset", "memcmp", "strlen", "strcmp", "strncmp", _
         "strchr", "strrchr", "malloc", "calloc", "realloc", "free", _
         "printf", "time", _
         "abs", "labs", "llabs", "sqrt", "sqrtf", "floor", "floorf", _
         "ceil", "ceilf", "pow", "powf", "sin", "cos", "tan", "asin", "acos", _
         "atan", "atan2", "exp", "log", "log10", "fmod", "round", "trunc", _
         "fabs", "frexp", "ldexp"
        Return -1
    End Select
    Return 0
End Function

Private Function IsCBodyRuntimeMathProcedure( _
    ByVal procedureName As String _
) As Long
    ' FreeBASIC spells these CRT math declarations with a trailing underscore.
    Select Case procedureName
    Case "sin", "cos", "tan", "asin", "acos", "atan", "atan2", _
         "exp", "log"
        Return -1
    End Select
    Return 0
End Function

Private Function CBodyCallName( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal procedureName As String _
) As String
    Dim lookupName As String = CBodyBuiltinCallTarget(procedureName)
    If lookupName = "" Then lookupName = procedureName
    Dim index As Long = CBodyProcedureIndex(translation, lookupName)
    If index >= 0 Then
        Dim freeBasicName As String = _
            CBodySymbolFreeBasicName(translation, catalog, index)
        If IsCBodyRuntimeProcedure(lookupName) <> 0 AndAlso _
           freeBasicName = "c2fb_crt_" & lookupName Then
            If lookupName = "abs" Then
                ' C abs is undefined for INT_MIN; FreeBASIC Abs preserves its
                ' defined integer behavior without an unresolved abs_ import.
                Return "Abs"
            End If
            Dim mappedFreeBasicName As String = _
                translation.symbolTable.symbols(index).freeBasicName
            If mappedFreeBasicName <> "" AndAlso _
               LCase(mappedFreeBasicName) <> LCase(lookupName) Then _
                Return mappedFreeBasicName
            Dim signatureIndex As Long = _
                FbBodyCallSignatureIndex(catalog, lookupName)
            If signatureIndex < 0 Then _
                signatureIndex = FbBodyCallSignatureAliasIndex( _
                    catalog, lookupName)
            If signatureIndex >= 0 AndAlso _
               catalog.bodyCallSignatures(signatureIndex).canDeclare <> 0 AndAlso _
               catalog.bodyCallSignatures(signatureIndex).parameterCount >= 0 Then
                ' Prefer the project's explicit C-alias declaration when it
                ' supplies a callable signature for this runtime symbol.
                Return catalog.bodyCallSignatures(signatureIndex).fbName
            End If
        End If
        Return freeBasicName
    End If
    index = FbBodyCallSignatureIndex(catalog, lookupName)
    If index >= 0 Then Return catalog.bodyCallSignatures(index).fbName
    Return lookupName
End Function

Private Sub AddCBodyCallableSymbols( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    names() As String, ByRef nameCount As Long _
)
    For i As Long = 0 To translation.symbolTable.symbolCount - 1
        With translation.symbolTable.symbols(i)
            If .body.isDeclared = 0 Then Continue For
            If .ambiguous <> 0 OrElse .body.isAmbiguous <> 0 Then Continue For
            Dim alreadyAvailable As Long = C2fbNameListContains(names(), nameCount, .sourceName)
            Dim signatureIndex As Long = _
                FbBodyCallSignatureIndex(catalog, .sourceName)
            If signatureIndex < 0 Then _
                signatureIndex = FbBodyCallSignatureAliasIndex( _
                    catalog, .sourceName)
            If signatureIndex >= 0 AndAlso _
               catalog.bodyCallSignatures(signatureIndex).canDeclare <> 0 AndAlso _
               catalog.bodyCallSignatures(signatureIndex).parameterCount >= 0 Then
                ' A public C-alias declaration can provide the call signature
                ' even when its C name is absent from the ordinary callable index.
                .body.callNameOverride = _
                    catalog.bodyCallSignatures(signatureIndex).fbName
                alreadyAvailable = -1
            ElseIf signatureIndex >= 0 Then
                ' A conflicting project signature cannot type this call. Use
                ' the C declaration as an external ABI binding instead.
                alreadyAvailable = 0
            End If
            If .body.hasDefinition = 0 AndAlso alreadyAvailable = 0 Then
                If .body.isStatic <> 0 Then Continue For
                If IsCBodyRuntimeProcedure(.sourceName) <> 0 Then
                    .body.isRuntime = -1
                    .body.callNameOverride = "c2fb_crt_" & .sourceName
                Else
                    .body.isExternal = -1
                    .body.callNameOverride = CBodyExternalProcedureFreeBasicName( _
                        translation, catalog, .sourceName)
                End If
            End If
            If .body.hasDefinition <> 0 AndAlso alreadyAvailable = 0 AndAlso _
               .body.isExternal = 0 Then _
                .body.needsDefinition = -1
            If alreadyAvailable = 0 Then
                If nameCount > UBound(names) Then ReDim Preserve names(0 To UBound(names) * 2 + 1)
                names(nameCount) = .sourceName
                nameCount += 1
            End If
        End With
    Next
End Sub

Private Function CBodyUsesIdentifier( _
    ByVal bodyText As String, ByVal identifier As String _
) As Long
    If identifier = "" Then Return 0
    Dim position As Long = 1
    Dim quoteByte As Long = 0
    While position <= Len(bodyText)
        Dim currentByte As Long = Asc(bodyText, position)
        If quoteByte <> 0 Then
            If currentByte = quoteByte Then
                If quoteByte = Asc(Chr(34)) AndAlso _
                   position < Len(bodyText) AndAlso _
                   Asc(bodyText, position + 1) = quoteByte Then
                    position += 2
                    Continue While
                End If
                quoteByte = 0
            End If
            position += 1
        ElseIf currentByte = Asc("'") Then
            While position <= Len(bodyText) AndAlso _
                  Asc(bodyText, position) <> 10
                position += 1
            Wend
        ElseIf currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
            position += 1
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(bodyText) AndAlso _
                  IsIdentifierPart(Asc(bodyText, position)) <> 0
                position += 1
            Wend
            If LCase(Mid(bodyText, tokenStart, position - tokenStart)) = _
               LCase(identifier) Then Return -1
        Else
            position += 1
        End If
    Wend
    Return 0
End Function

Private Function CBodyUsesProcedure(ByVal bodyText As String, ByVal procedureName As String) As Long
    If procedureName = "" Then Return 0
    Dim bodyLength As Long = Len(bodyText)
    Dim procedureLength As Long = Len(procedureName)
    If bodyLength = 0 OrElse procedureLength > bodyLength Then Return 0
    Dim bodyBytes As UByte Ptr = CPtr(UByte Ptr, StrPtr(bodyText))
    Dim procPtrPrefixLength As Long = Len("ProcPtr(")
    Dim position As Long = 1
    Dim quoted As Long = 0
    While position <= bodyLength
        Dim quotePosition As Long = _
            InStr(position, bodyText, Chr(34))
        If quoted <> 0 Then
            If quotePosition = 0 Then Return 0
            quoted = 0
            position = quotePosition + 1
            Continue While
        End If

        ' Let the runtime string search skip ordinary body text. Dependency
        ' passes ask this question for many names in the same large function,
        ' so walking every byte in FreeBASIC for every query dominates bulk runs.
        Dim namePosition As Long = _
            InStr(position, bodyText, procedureName)
        If namePosition = 0 Then Return 0
        If quotePosition > 0 AndAlso quotePosition < namePosition Then
            quoted = -1
            position = quotePosition + 1
            Continue While
        End If

        Dim nextPosition As Long = namePosition + procedureLength
        If nextPosition <= bodyLength AndAlso _
           bodyBytes[nextPosition - 1] = Asc("(") AndAlso _
           (namePosition = 1 OrElse _
            IsIdentifierPart(bodyBytes[namePosition - 2]) = 0) Then _
            Return -1

        If nextPosition <= bodyLength AndAlso _
           bodyBytes[nextPosition - 1] = Asc(")") AndAlso _
           namePosition > procPtrPrefixLength Then
            Dim prefixMatches As Long = -1
            Dim prefixStart As Long = namePosition - procPtrPrefixLength
            For prefixIndex As Long = 0 To procPtrPrefixLength - 1
                If bodyBytes[prefixStart + prefixIndex - 1] <> _
                   Asc("ProcPtr(", prefixIndex + 1) Then
                    prefixMatches = 0
                    Exit For
                End If
            Next
            If prefixMatches <> 0 Then Return -1
        End If

        ' Advance one byte so overlapping occurrences remain visible.
        position = namePosition + 1
    Wend
    Return 0
End Function

Private Function CBodyExistingProcedureSatisfiesDependency( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceName As String _
) As Long
    If C2fbNameListContains( _
        catalog.existingProcedureNames(), catalog.existingProcedureNameCount, _
        sourceName) <> 0 Then Return -1
    Dim freeBasicName As String = CBodyCallName(translation, catalog, sourceName)
    If freeBasicName <> "" AndAlso C2fbNameListContains( _
        catalog.existingProcedureNames(), catalog.existingProcedureNameCount, _
        freeBasicName) <> 0 Then Return -1
    Return 0
End Function

Private Function CBodyCallsMissingRequiredDefinition( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal bodyText As String, _
    ByRef procedureIndexByName As C2fbStringIndexMapModel, _
    ByRef candidateIndexByName As C2fbStringIndexMapModel, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long, _
    ByRef missingProcedureName As String _
) As Long
    missingProcedureName = ""
    Dim position As Long = 1
    Dim quoteByte As Long = 0
    While position <= Len(bodyText)
        If quoteByte <> 0 Then
            If Asc(bodyText, position) = quoteByte Then
                If quoteByte = Asc(Chr(34)) AndAlso _
                   position < Len(bodyText) AndAlso _
                   Asc(bodyText, position + 1) = quoteByte Then
                    position += 2
                    Continue While
                End If
                quoteByte = 0
            End If
            position += 1
        ElseIf Mid(bodyText, position, 2) = "/'" Then
            Dim closePosition As Long = InStr(position + 2, bodyText, "'/")
            If closePosition = 0 Then Return 0
            position = closePosition + 2
        ElseIf Asc(bodyText, position) = Asc("'") Then
            While position <= Len(bodyText) AndAlso _
                  Asc(bodyText, position) <> Asc(Chr(10))
                position += 1
            Wend
        ElseIf Asc(bodyText, position) = Asc(Chr(34)) Then
            quoteByte = Asc(Chr(34))
            position += 1
        ElseIf IsIdentifierStart(Asc(bodyText, position)) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(bodyText) AndAlso _
                  IsIdentifierPart(Asc(bodyText, position)) <> 0
                position += 1
            Wend
            Dim tokenText As String = LCase(Mid( _
                bodyText, tokenStart, position - tokenStart))
            Dim nextPosition As Long = position
            While nextPosition <= Len(bodyText) AndAlso _
                  IsSpaceByte(Asc(bodyText, nextPosition)) <> 0
                nextPosition += 1
            Wend
            Dim isCall As Long = CInt( _
                nextPosition <= Len(bodyText) AndAlso _
                Asc(bodyText, nextPosition) = Asc("(")) * -1
            If isCall = 0 Then
                Dim previousPosition As Long = tokenStart - 1
                While previousPosition > 0 AndAlso _
                      IsSpaceByte(Asc(bodyText, previousPosition)) <> 0
                    previousPosition -= 1
                Wend
                If previousPosition > 0 AndAlso _
                   Asc(bodyText, previousPosition) = Asc("(") Then
                    previousPosition -= 1
                    While previousPosition > 0 AndAlso _
                          IsSpaceByte(Asc(bodyText, previousPosition)) <> 0
                        previousPosition -= 1
                    Wend
                    Dim procPtrEnd As Long = previousPosition
                    While previousPosition > 0 AndAlso _
                          IsIdentifierPart(Asc(bodyText, previousPosition)) <> 0
                        previousPosition -= 1
                    Wend
                    If LCase(Mid(bodyText, previousPosition + 1, _
                        procPtrEnd - previousPosition)) = "procptr" Then _
                        isCall = -1
                End If
            End If

            If isCall <> 0 Then
                Dim symbolIndex As Long = C2fbStringIndexMapLookup( _
                    procedureIndexByName, tokenText)
                If symbolIndex >= 0 AndAlso symbolIndex < _
                   translation.symbolTable.symbolCount Then
                    With translation.symbolTable.symbols(symbolIndex)
                        Dim candidateIndex As Long = _
                            C2fbStringIndexMapLookup( _
                                candidateIndexByName, .sourceName)
                        If candidateIndex < 0 OrElse _
                           candidateIndex >= candidateCount Then
                            If CBodyExistingProcedureSatisfiesDependency( _
                                translation, catalog, .sourceName) <> 0 Then _
                                Continue While
                            missingProcedureName = .sourceName
                            Return -1
                        End If
                        If candidates(candidateIndex).duplicate <> 0 OrElse _
                           candidates(candidateIndex).source = "" Then
                            If CBodyExistingProcedureSatisfiesDependency( _
                                translation, catalog, .sourceName) <> 0 Then _
                                Continue While
                            missingProcedureName = .sourceName
                            Return -1
                        End If
                    End With
                End If
            End If
        Else
            position += 1
        End If
    Wend
    Return 0
End Function

Private Function CBodyCallbackArrayUsesMissingDefinition( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal bodyText As String, _
    ByRef candidateIndexByName As C2fbStringIndexMapModel, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long, _
    ByRef missingProcedureName As String _
) As Long
    missingProcedureName = ""
    For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
        With translation.body.externalObjects(objectIndex)
            If .isArray = 0 OrElse .isStatic = 0 OrElse _
               .initializerText = "" OrElse _
               CBodyUsesIdentifier(bodyText, .freeBasicName) = 0 Then _
                Continue For
            For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
                With translation.symbolTable.symbols(symbolIndex)
                    If .body.isDeclared = 0 OrElse .body.hasDefinition = 0 Then _
                        Continue For
                    Dim freeBasicName As String = _
                        CBodySymbolFreeBasicName(translation, catalog, symbolIndex)
                    If CBodyUsesIdentifier( _
                        translation.body.externalObjects(objectIndex).initializerText, _
                        freeBasicName) = 0 Then Continue For

                    Dim targetCandidateIndex As Long = _
                        C2fbStringIndexMapLookup( _
                            candidateIndexByName, .sourceName)
                    If targetCandidateIndex >= 0 AndAlso _
                       targetCandidateIndex < candidateCount AndAlso _
                       candidates(targetCandidateIndex).duplicate = 0 AndAlso _
                       candidates(targetCandidateIndex).source <> "" Then _
                        Continue For

                    Dim signatureIndex As Long = _
                        FbBodyCallSignatureIndex(catalog, .sourceName)
                    If signatureIndex < 0 Then _
                        signatureIndex = FbBodyCallSignatureAliasIndex( _
                            catalog, .sourceName)
                    If signatureIndex >= 0 AndAlso _
                       catalog.bodyCallSignatures(signatureIndex).canDeclare <> 0 Then _
                        Continue For
                    If C2fbNameListContains( _
                        catalog.existingProcedureNames(), _
                        catalog.existingProcedureNameCount, .sourceName) <> 0 OrElse _
                       C2fbNameListContains( _
                        catalog.existingProcedureNames(), _
                        catalog.existingProcedureNameCount, freeBasicName) <> 0 Then _
                        Continue For

                    missingProcedureName = .sourceName
                    Return -1
                End With
            Next
        End With
    Next
    Return 0
End Function

Private Sub FilterCBodyDependencies( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long _
)
    ' Remove callers whose required file-local body failed conversion. Repeat
    ' to propagate failure through chains and recursive groups without stubs.
    Dim procedureIndexByName As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(procedureIndexByName)
    For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
        With translation.symbolTable.symbols(symbolIndex)
            If .body.isDeclared = 0 OrElse _
               (.body.needsDefinition = 0 AndAlso _
                (.body.isStatic = 0 OrElse .body.hasDefinition = 0)) Then _
                Continue For
            Dim freeBasicName As String = LCase( _
                CBodySymbolFreeBasicName(translation, catalog, symbolIndex))
            If freeBasicName = "" Then Continue For
            Dim addStatus As Long = AddC2fbStringIndexMapEntry( _
                procedureIndexByName, freeBasicName, symbolIndex)
            If addStatus = 0 Then _
                ReportError("body dependency procedure index exceeds the configured limit")
        End With
    Next
    Dim candidateIndexByName As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(candidateIndexByName)
    For candidateIndex As Long = 0 To candidateCount - 1
        Dim addStatus As Long = AddC2fbStringIndexMapEntry( _
            candidateIndexByName, candidates(candidateIndex).name, candidateIndex)
        If addStatus = 0 Then _
            ReportError("body dependency candidate index exceeds the configured limit")
    Next

    Dim changed As Long
    Do
        changed = 0
        For i As Long = 0 To candidateCount - 1
            If candidates(i).source = "" Then Continue For
            Dim missingProcedureName As String
            Dim hasMissingDefinition As Long = CBodyCallsMissingRequiredDefinition( _
                translation, catalog, candidates(i).source, procedureIndexByName, _
                candidateIndexByName, candidates(), candidateCount, _
                missingProcedureName)
            If hasMissingDefinition = 0 Then
                hasMissingDefinition = CBodyCallbackArrayUsesMissingDefinition( _
                    translation, catalog, candidates(i).source, _
                    candidateIndexByName, candidates(), candidateCount, _
                    missingProcedureName)
            End If
            If hasMissingDefinition <> 0 Then
                candidates(i).source = ""
                If missingProcedureName <> "" Then _
                    candidates(i).skipMessage = _
                        "requires unconverted C function " & missingProcedureName
                changed = -1
            End If
        Next
    Loop While changed <> 0
End Sub

Private Sub IndexCBodyTypeAliasesFromDeclarations( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
)
    ReDim translation.body.aliases(0 To 255)
    translation.body.aliasCount = 0
    ReDim translation.body.pointerToArrayParameters(0 To 255)
    translation.body.pointerToArrayParameterCount = 0
    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind = C2FB_DECLARATION_RECORD Then
                Dim sourceRecordName As String = .recordTag
                If sourceRecordName = "" Then sourceRecordName = .recordAlias
                If .isConditional = 0 AndAlso .isTypedef <> 0 AndAlso _
                   sourceRecordName <> "" AndAlso .recordTail <> "" AndAlso _
                   (.recordKind = C2FB_RECORD_STRUCT OrElse _
                    .recordKind = C2FB_RECORD_UNION) Then
                    Dim parts() As String
                    Dim aliasNames() As String
                    Dim bindingOrders() As String
                    Dim partCount As Long
                    If ParseGenericRecordTypedefTail( _
                        .recordTail, parts(), aliasNames(), bindingOrders(), _
                        partCount) <> 0 Then
                        For partIndex As Long = 0 To partCount - 1
                            Dim pointerCount As Long = 0
                            Dim plainRecordAlias As Long = -1
                            For bindingIndex As Long = 1 To Len(bindingOrders(partIndex))
                                If Mid(bindingOrders(partIndex), bindingIndex, 1) = "P" Then
                                    pointerCount += 1
                                Else
                                    plainRecordAlias = 0
                                    Exit For
                                End If
                            Next
                            If plainRecordAlias = 0 Then Continue For
                            RecordCBodyRecordTypedefAlias( _
                                translation, aliasNames(partIndex), sourceRecordName, _
                                pointerCount)
                        Next
                    End If
                End If
                Continue For
            End If
            If .entryKind <> C2FB_DECLARATION_PLAIN OrElse _
               .isConditional <> 0 Then Continue For
            RecordCBodyTypeAlias( _
                translation, catalog, translation.sourceUnit.declarations(declarationIndex))
        End With
    Next
End Sub

Private Function CBodyZeroStaticAggregateInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String _
) As Long
    sourceText = Trim(sourceText)
    If Left(sourceText, 1) = "{" Then
        If Right(sourceText, 1) <> "}" Then Return 0
        Dim initializerBody As String = Trim(Mid( _
            sourceText, 2, Len(sourceText) - 2))
        If initializerBody = "" Then Return -1
        If Right(initializerBody, 1) = "," Then _
            initializerBody = RTrim(Left( _
                initializerBody, Len(initializerBody) - 1))

        Dim values() As String
        Dim valueCount As Long
        If SplitSimpleCList( _
            initializerBody, values(), valueCount, 0, _
            MAX_GENERIC_STATIC_INITIALIZER_VALUES) = 0 OrElse _
           valueCount <= 0 Then Return 0
        For valueIndex As Long = 0 To valueCount - 1
            If CBodyZeroStaticAggregateInitializer( _
                translation, values(valueIndex)) = 0 Then Return 0
        Next
        Return -1
    End If

    If GenericNullPointerConstantText(sourceText) <> 0 Then Return -1
    Dim integerValue As Long
    If EvaluateGenericEnumIntegerValue( _
        translation, sourceText, integerValue) = 0 Then Return 0
    Return CInt(integerValue = 0) * -1
End Function

Private Sub IndexCBodyExternalObjectsFromDeclarations( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
)
    ReDim translation.body.externalObjects(0 To 255)
    translation.body.externalObjectCount = 0

    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        Dim declaration As C2fbDeclarationModel = _
            translation.sourceUnit.declarations(declarationIndex)
        ' Block-local record declarations are parsed separately with their
        ' owning function. Treating their declarators as module storage creates
        ' fake globals for objects such as a local union used for bit casts.
        If declaration.isBlockLocal <> 0 Then Continue For
        Dim inlineRecordTail As String
        If declaration.entryKind = C2FB_DECLARATION_RECORD Then
            ' C permits a file-scope object to follow a named record body in
            ' the same declaration. Scan that tail as a variable declarator
            ' so candidates can bind a file-local table to a FreeBASIC object.
            If declaration.isTypedef <> 0 OrElse declaration.recordTail = "" Then _
                Continue For
            inlineRecordTail = declaration.recordTail
            Dim recordTypePrefix As String = declaration.recordPrefix
            If declaration.recordKind = C2FB_RECORD_ENUM AndAlso _
               declaration.recordTag = "" Then
                ' An anonymous enum has no C tag to repeat in the declarator.
                ' C2FB emits enum storage with its C int representation, so use
                ' that primitive while indexing the following file-scope object.
                Dim prefixTokens() As String
                Dim prefixTokenCount As Long
                TokenizeCDeclaration( _
                    declaration.recordPrefix, prefixTokens(), prefixTokenCount)
                recordTypePrefix = ""
                For prefixIndex As Long = 0 To prefixTokenCount - 1
                    If prefixTokens(prefixIndex) = "enum" Then Continue For
                    If recordTypePrefix <> "" Then recordTypePrefix &= " "
                    recordTypePrefix &= prefixTokens(prefixIndex)
                Next
                If recordTypePrefix <> "" Then recordTypePrefix &= " "
                recordTypePrefix &= "int"
            ElseIf (declaration.recordKind = C2FB_RECORD_STRUCT OrElse _
                    declaration.recordKind = C2FB_RECORD_UNION) AndAlso _
                   declaration.recordTag = "" AndAlso _
                   declaration.recordAlias = "" Then
                ' Header tables often use a file-static anonymous record.
                ' Give its layout a private name before indexing the object.
                Dim generatedRecordName As String
                If RegisterCBodyAnonymousRecord( _
                    translation, catalog, declaration.recordBody, _
                    generatedRecordName, declaration.recordKind, _
                    "c2fb_static_record_", -1) = 0 Then _
                    Continue For
                Dim prefixTokens() As String
                Dim prefixTokenCount As Long
                TokenizeCDeclaration( _
                    declaration.recordPrefix, prefixTokens(), prefixTokenCount)
                recordTypePrefix = ""
                For prefixIndex As Long = 0 To prefixTokenCount - 1
                    If prefixTokens(prefixIndex) = "struct" OrElse _
                       prefixTokens(prefixIndex) = "union" Then Continue For
                    If recordTypePrefix <> "" Then recordTypePrefix &= " "
                    recordTypePrefix &= prefixTokens(prefixIndex)
                Next
                If recordTypePrefix <> "" Then recordTypePrefix &= " "
                recordTypePrefix &= generatedRecordName
            End If
            ' Keep a trailing initializer here. The declarator parser ignores
            ' top-level initializers while finding the object name, and later
            ' object indexing needs the original expression to emit storage.
            Dim recordVariableText As String = _
                recordTypePrefix & " " & declaration.recordTail
            TokenizeCDeclaration( _
                recordVariableText, declaration.tokens(), declaration.tokenCount)
            declaration.text = recordVariableText
            declaration.entryKind = C2FB_DECLARATION_PLAIN
        End If
        If declaration.entryKind <> C2FB_DECLARATION_PLAIN OrElse _
           declaration.isConditional <> 0 OrElse declaration.tokenCount < 2 Then Continue For

        Dim hasTypedef As Long = 0
        Dim hasStaticStorage As Long = 0
        Dim hasExternStorage As Long = 0
        For tokenIndex As Long = 0 To declaration.tokenCount - 1
            If declaration.tokens(tokenIndex) = "typedef" Then hasTypedef = -1
            If declaration.tokens(tokenIndex) = "static" Then hasStaticStorage = -1
            If declaration.tokens(tokenIndex) = "extern" Then hasExternStorage = -1
        Next
        If hasTypedef <> 0 Then Continue For

        Dim sourceRanges() As C2fbTokenRangeModel
        Dim sourceRangeCount As Long = 0
        If SplitC2fbTokenList( _
            declaration.tokens(), 0, declaration.tokenCount - 1, _
            sourceRanges(), sourceRangeCount) = 0 Then Continue For

        Dim commonType As String
        Dim firstName As String
        Dim firstBindingOrder As String
        Dim commonTypeTokenCount As Long
        If ParseGenericHeaderDeclaratorTokens( _
            declaration.tokens(), sourceRanges(0).firstToken, _
            sourceRanges(0).lastToken, commonType, firstName, _
            firstBindingOrder, commonTypeTokenCount) = 0 Then Continue For

        For partIndex As Long = 0 To sourceRangeCount - 1
            Dim itemTokens() As String
            Dim itemTokenCount As Long
            If BuildC2fbDeclaratorPartTokens( _
                declaration.tokens(), sourceRanges(), sourceRangeCount, _
                partIndex, commonTypeTokenCount, itemTokens(), _
                itemTokenCount) = 0 Then Continue For

            Dim itemCommonType As String
            Dim sourceName As String
            Dim bindingOrder As String
            Dim itemCommonTypeTokenCount As Long
            If ParseGenericHeaderDeclaratorTokens( _
                itemTokens(), 0, itemTokenCount - 1, itemCommonType, _
                sourceName, bindingOrder, itemCommonTypeTokenCount) = 0 Then _
                Continue For

            Dim pointerDepth As Long = 0
            Dim arrayDepth As Long = 0
            Dim hasFunctionOperator As Long = 0
            Dim hasUnsupportedOperator As Long = 0
            For bindingIndex As Long = 1 To Len(bindingOrder)
                Select Case Mid(bindingOrder, bindingIndex, 1)
                Case "P": pointerDepth += 1
                Case "A": arrayDepth += 1
                Case "F": hasFunctionOperator = -1
                Case Else: hasUnsupportedOperator = -1
                End Select
            Next
            If hasUnsupportedOperator <> 0 OrElse _
               arrayDepth > MAX_GENERIC_ARRAY_RANK Then Continue For
            If arrayDepth > 0 AndAlso Left(bindingOrder, 1) <> "A" Then _
                Continue For

            ' A typedef can supply the array operator without spelling
            ' brackets on this object declarator. Keep that storage shape in
            ' the body index so later expressions apply C array decay.
            Dim arrayTypedefAliasIndex As Long = -1
            Dim arrayTypedefIsConst As Long = 0
            If pointerDepth = 0 AndAlso arrayDepth = 0 AndAlso _
               hasFunctionOperator = 0 Then
                Dim arrayTypedefName As String = ""
                Dim arrayTypedefNameIsAmbiguous As Long = 0
                For typeIndex As Long = 0 To itemCommonTypeTokenCount - 1
                    Select Case itemTokens(typeIndex)
                    Case "const"
                        arrayTypedefIsConst = -1
                    Case "volatile", "restrict", "__restrict", "__restrict__", _
                         "static", "extern", "auto", "register", _
                         "_Thread_local", "__thread", "thread_local"
                        Continue For
                    Case Else
                        If arrayTypedefName <> "" Then
                            arrayTypedefNameIsAmbiguous = -1
                            Exit For
                        End If
                        arrayTypedefName = itemTokens(typeIndex)
                    End Select
                Next
                If arrayTypedefNameIsAmbiguous = 0 AndAlso _
                   arrayTypedefName <> "" Then
                    arrayTypedefAliasIndex = _
                        CBodyArrayTypeAliasIndexInContext( _
                            translation, arrayTypedefName)
                End If
            End If
            If arrayTypedefAliasIndex >= 0 Then arrayDepth = 1

            Dim isPrivateStatic As Long = CInt(hasStaticStorage <> 0) * -1
            Dim reusedStaticName As String = GenericStaticObjectReuseInPolicy( _
                translation.genericC.policy, sourceName)
            Dim itemAssignmentToken As Long
            If FindC2fbTopLevelAssignmentToken( _
                itemTokens(), 0, itemTokenCount - 1, _
                itemAssignmentToken) = 0 Then Continue For
            Dim sourceObjectHasInitializer As Long = _
                CInt(itemAssignmentToken >= 0) * -1
            Dim isGlobalDefinition As Long = 0
            If translation.body.includeGlobalDefinitions <> 0 AndAlso _
               (isPrivateStatic <> 0 OrElse hasExternStorage = 0 OrElse _
                sourceObjectHasInitializer <> 0) Then
                isGlobalDefinition = -1
            End If
            If reusedStaticName <> "" AndAlso isPrivateStatic = 0 Then _
                ReportError( _
                    "--reuse-static-object targets a non-static C object: " & _
                    sourceName)
            Dim callbackArrayResult As C2fbCallbackTypeResultModel
            Dim hasCallbackArrayType As Long = 0
            If arrayDepth <> 0 Then
                hasCallbackArrayType = CBodyCallbackArrayTypeInContext( _
                    translation, catalog, itemTokens(), itemTokenCount, _
                    sourceName, callbackArrayResult)
            End If
            ' A fixed, private callback table has the same module lifetime as
            ' the C object. Each dimension shares one procedure-pointer type.
            If arrayDepth <> 0 AndAlso _
               (hasFunctionOperator <> 0 OrElse hasCallbackArrayType <> 0) Then
                If arrayDepth < 1 OrElse _
                   arrayDepth > MAX_GENERIC_ARRAY_RANK OrElse _
                   (hasFunctionOperator <> 0 AndAlso pointerDepth <> 1) OrElse _
                       (isPrivateStatic = 0 AndAlso isGlobalDefinition = 0) Then
                    Continue For
                End If

                Dim callbackArrayInitializer As String
                CBodySourceObjectInitializer( _
                    declaration.text, sourceName, callbackArrayInitializer)
                Dim callbackArrayCount As Long = 0
                Dim callbackArrayRank As Long = 0
                Dim callbackArrayDimensions As String
                Dim callbackArrayDimensionCounts() As Long
                Dim callbackArrayIsUnsized As Long = 0
                If CBodyFixedExternalArrayDimensions( _
                    translation, itemTokens(), itemTokenCount, _
                    itemCommonTypeTokenCount, sourceName, _
                    callbackArrayInitializer, callbackArrayDimensionCounts(), _
                    callbackArrayCount, callbackArrayRank, _
                    callbackArrayDimensions, callbackArrayIsUnsized) = 0 OrElse _
                   callbackArrayCount <= 0 OrElse _
                   callbackArrayRank <> arrayDepth Then
                    Continue For
                End If

                Dim callbackArrayConst As Long = 0
                Dim callbackArrayNamePosition As Long = -1
                Dim callbackArrayPointerPosition As Long = -1
                For tokenIndex As Long = 0 To itemTokenCount - 1
                    If itemTokens(tokenIndex) = "*" Then _
                        callbackArrayPointerPosition = tokenIndex
                    If itemTokens(tokenIndex) = sourceName Then
                        callbackArrayNamePosition = tokenIndex
                        Exit For
                    End If
                Next
                If callbackArrayNamePosition >= 0 AndAlso _
                   callbackArrayPointerPosition >= 0 Then
                    For tokenIndex As Long = callbackArrayPointerPosition + 1 To _
                        callbackArrayNamePosition - 1
                        If itemTokens(tokenIndex) = "const" Then _
                            callbackArrayConst = -1
                    Next
                ElseIf callbackArrayNamePosition >= 0 Then
                    For tokenIndex As Long = 0 To callbackArrayNamePosition - 1
                        If itemTokens(tokenIndex) = "const" Then _
                            callbackArrayConst = -1
                    Next
                End If

                Dim callbackArrayInitialValue As String
                If reusedStaticName = "" Then
                    If TranslateCBodyStaticCallbackArrayInitializer( _
                        translation, catalog, callbackArrayInitializer, _
                        callbackArrayResult.freeBasicType, _
                        callbackArrayDimensionCounts(), callbackArrayRank, _
                        callbackArrayCount, callbackArrayInitialValue) = 0 Then
                        Continue For
                    End If
                End If
                RecordCBodyExternalObjectInContext( _
                    translation, catalog, sourceName, sourceName, _
                    callbackArrayResult.freeBasicType, callbackArrayCount, _
                    -1, callbackArrayConst, isPrivateStatic, _
                    callbackArrayInitialValue, _
                    CInt(reusedStaticName <> "") * -1, callbackArrayIsUnsized, _
                    callbackArrayRank, callbackArrayDimensions, _
                    isGlobalDefinition, pointerDepth, _
                    CBodyObjectVolatileMask( _
                        itemTokens(), itemTokenCount, _
                        itemCommonTypeTokenCount, sourceName))
                Continue For
            End If

            If hasFunctionOperator <> 0 Then
                ' A file-scope pointer to a function is a callable object, not
                ' a procedure declaration. Keep its callback signature for
                ' body calls through the object name.
                Dim callbackResult As C2fbCallbackTypeResultModel
                Dim callbackDeclaratorLastToken As Long = itemTokenCount - 1
                Dim callbackAssignmentToken As Long
                If FindC2fbTopLevelAssignmentToken( _
                    itemTokens(), 0, itemTokenCount - 1, _
                    callbackAssignmentToken) <> 0 AndAlso _
                   callbackAssignmentToken >= 0 Then
                    ' The callback resolver accepts a C declarator, not its
                    ' initializer. Keep the initializer for the storage pass
                    ' below, but do not let it hide a direct function pointer.
                    callbackDeclaratorLastToken = callbackAssignmentToken - 1
                End If
                ResolveCBodyCallbackTypeInContext( _
                    translation, catalog, itemTokens(), 0, _
                    callbackDeclaratorLastToken, _
                    callbackResult, 0, C2FB_TYPE_MAPPING_BODY)
                If callbackResult.status <> C2FB_CALLBACK_TYPE_CONVERTED OrElse _
                   callbackResult.callbackName <> sourceName OrElse _
                   callbackResult.freeBasicType = "" OrElse _
                   callbackResult.pointerDepth <> 1 Then Continue For
                Dim callbackConstObject As Long = 0
                Dim sourceNamePosition As Long = -1
                Dim lastPointerPosition As Long = -1
                For tokenIndex As Long = 0 To itemTokenCount - 1
                    If itemTokens(tokenIndex) = "*" Then _
                        lastPointerPosition = tokenIndex
                    If itemTokens(tokenIndex) = sourceName Then
                        sourceNamePosition = tokenIndex
                        Exit For
                    End If
                Next
                If sourceNamePosition >= 0 AndAlso lastPointerPosition >= 0 Then
                    For tokenIndex As Long = lastPointerPosition + 1 To _
                        sourceNamePosition - 1
                        If itemTokens(tokenIndex) = "const" Then _
                            callbackConstObject = -1
                    Next
                End If
                Dim callbackInitializer As String
                Dim callbackInitialValue As String
                If (isPrivateStatic <> 0 OrElse isGlobalDefinition <> 0) AndAlso _
                   reusedStaticName = "" Then
                    Dim callbackAssignmentToken As Long
                    If FindC2fbTopLevelAssignmentToken( _
                        itemTokens(), 0, itemTokenCount - 1, _
                        callbackAssignmentToken) = 0 Then Continue For
                    If callbackAssignmentToken >= 0 Then
                        If CBodySourceObjectInitializer( _
                            declaration.text, sourceName, callbackInitializer) = 0 Then _
                            Continue For
                        If TranslateCBodyCallbackInitializer( _
                            translation, catalog, callbackInitializer, _
                            callbackResult.freeBasicType, _
                            callbackInitialValue) = 0 Then Continue For
                    ElseIf callbackConstObject <> 0 Then
                        callbackInitialValue = "0"
                    End If
                End If
                RecordCBodyExternalObjectInContext( _
                    translation, catalog, sourceName, sourceName, _
                    callbackResult.freeBasicType, 0, 0, callbackConstObject, _
                    isPrivateStatic, callbackInitialValue, _
                    CInt(reusedStaticName <> "") * -1, 0, 0, "", _
                    isGlobalDefinition, pointerDepth, _
                    CBodyObjectVolatileMask( _
                        itemTokens(), itemTokenCount, _
                        itemCommonTypeTokenCount, sourceName))
                Continue For
            End If

            Dim arrayCount As Long = 0
            Dim arrayRank As Long = 0
            Dim arrayDimensions As String
            Dim arrayDimensionCounts() As Long
            Dim isUnsizedArray As Long = 0
            Dim arrayInitializerText As String
            CBodySourceObjectInitializer( _
                declaration.text, sourceName, arrayInitializerText)
            If arrayTypedefAliasIndex >= 0 Then
                With translation.body.aliases(arrayTypedefAliasIndex)
                    arrayCount = .arrayCount
                    arrayRank = 1
                    arrayDimensions = Trim(Str(.arrayCount)) & "ULL"
                    ReDim arrayDimensionCounts(0 To 0)
                    arrayDimensionCounts(0) = .arrayCount
                End With
            ElseIf arrayDepth > 0 AndAlso CBodyFixedExternalArrayDimensions( _
                translation, itemTokens(), itemTokenCount, itemCommonTypeTokenCount, _
                sourceName, arrayInitializerText, arrayDimensionCounts(), _
                arrayCount, arrayRank, arrayDimensions, isUnsizedArray) = 0 Then
                If arrayDepth = 1 AndAlso inlineRecordTail <> "" AndAlso _
                   CBodyInlineRecordArrayCount( _
                       inlineRecordTail, sourceName, arrayCount) <> 0 Then
                    isUnsizedArray = 0
                    arrayRank = 1
                    arrayDimensions = Trim(Str(arrayCount)) & "ULL"
                    ReDim arrayDimensionCounts(0 To 0)
                    arrayDimensionCounts(0) = arrayCount
                ElseIf isUnsizedArray = 0 OrElse hasExternStorage = 0 OrElse _
                       hasStaticStorage <> 0 Then
                    Continue For
                End If
            End If

            Dim typeTokens() As String
            ReDim typeTokens(0 To MAX_TYPE_WORDS - 1)
            Dim typeTokenCount As Long = 0
            Dim typeTokensComplete As Long = -1
            For typeIndex As Long = 0 To itemCommonTypeTokenCount - 1
                Select Case itemTokens(typeIndex)
                Case "_Thread_local", "__thread", "thread_local"
                    Continue For
                End Select
                If typeTokenCount >= MAX_TYPE_WORDS Then
                    typeTokensComplete = 0
                    Exit For
                End If
                typeTokens(typeTokenCount) = itemTokens(typeIndex)
                typeTokenCount += 1
            Next
            For pointerIndex As Long = 1 To pointerDepth
                If typeTokenCount >= MAX_TYPE_WORDS Then
                    typeTokensComplete = 0
                    Exit For
                End If
                typeTokens(typeTokenCount) = "*"
                typeTokenCount += 1
            Next
            If typeTokensComplete = 0 OrElse typeTokenCount = 0 Then Continue For

            Dim resolvedType As C2fbResolvedTypeModel
            If arrayTypedefAliasIndex >= 0 Then
                With translation.body.aliases(arrayTypedefAliasIndex)
                    resolvedType.status = C2FB_TYPE_RESOLUTION_RESOLVED
                    resolvedType.freeBasicType = .arrayElementType
                    resolvedType.pointerCount = 0
                    resolvedType.isConst = CInt( _
                        .isConst <> 0 OrElse arrayTypedefIsConst <> 0) * -1
                End With
            Else
                ResolveC2fbTypeModel( _
                    translation, catalog, typeTokens(), 0, typeTokenCount - 1, _
                    resolvedType)
            End If
            If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
               resolvedType.freeBasicType = "" OrElse _
               resolvedType.freeBasicType = "void" Then Continue For

            Dim freeBasicType As String = resolvedType.freeBasicType
            If resolvedType.isConst <> 0 AndAlso _
               (resolvedType.pointerCount > 0 OrElse arrayDepth > 0) AndAlso _
               Left(freeBasicType, 6) <> "Const " Then _
                freeBasicType = "Const " & freeBasicType
            Dim isConstObject As Long = CInt( _
                resolvedType.isConst <> 0 AndAlso _
                resolvedType.pointerCount = 0 AndAlso arrayDepth = 0)
            Dim initializerText As String
            If (isPrivateStatic <> 0 OrElse isGlobalDefinition <> 0) AndAlso _
               reusedStaticName = "" Then
                Dim assignmentToken As Long
                If FindC2fbTopLevelAssignmentToken( _
                    itemTokens(), 0, itemTokenCount - 1, _
                    assignmentToken) = 0 Then Continue For
                If assignmentToken >= 0 Then
                    Dim initializerLastToken As Long = itemTokenCount - 1
                    If itemTokens(initializerLastToken) = ";" Then _
                        initializerLastToken -= 1
                    If assignmentToken >= initializerLastToken Then Continue For
                    Dim sourceInitializer As String
                    If CBodySourceObjectInitializer( _
                        declaration.text, sourceName, sourceInitializer) = 0 Then _
                        Continue For
                    If arrayDepth <> 0 Then
                        If arrayCount <= 0 Then Continue For
                        Dim staticRecordArrayStatus As Long = 0
                        If arrayRank = 1 AndAlso pointerDepth = 0 Then _
                            staticRecordArrayStatus = _
                                TranslateCBodyStaticRecordArrayInitializer( _
                                    translation, catalog, sourceInitializer, _
                                    freeBasicType, arrayCount, initializerText)
                        If staticRecordArrayStatus = 0 Then
                            If arrayRank > 1 Then
                                If TranslateCBodyMultidimensionalStaticArrayInitializer( _
                                    translation, sourceInitializer, freeBasicType, _
                                    arrayDimensionCounts(), arrayRank, arrayCount, _
                                    CInt(pointerDepth > 0) * -1, initializerText) = 0 Then
                                    If translation.body.assumeZeroStaticAggregates = 0 OrElse _
                                       CBodyZeroStaticAggregateInitializer( _
                                           translation, sourceInitializer) = 0 Then _
                                        Continue For
                                    initializerText = ""
                                End If
                            Else
                                Dim staticInitializerStatus As Long = _
                                    TranslateGenericModuleStaticInitializer( _
                                    translation, sourceInitializer, freeBasicType, -1, _
                                    CInt(pointerDepth > 0) * -1, 0, _
                                    CInt(IsGenericCharacterArrayType( _
                                        translation, itemCommonType, freeBasicType, 0) <> 0) * -1, _
                                    0, 0, arrayCount, initializerText, "")
                                If staticInitializerStatus = 0 Then
                                    If translation.body.assumeZeroStaticAggregates = 0 OrElse _
                                       CBodyZeroStaticAggregateInitializer( _
                                           translation, sourceInitializer) = 0 Then _
                                        Continue For
                                    initializerText = ""
                                End If
                            End If
                        End If
                    Else
                        Dim sourceRecord As String = CBodyRecordName( _
                            translation, catalog, freeBasicType)
                        If sourceRecord <> "" AndAlso _
                           Left(LTrim(sourceInitializer), 1) = "{" Then
                            Dim emptySimpleContext As SimpleBodyContext
                            Dim emptyCallableNames(0 To 0) As String
                            Dim emptyParameterNames(0 To 0) As String
                            Dim emptyParameterAliases(0 To 0) As String
                            Dim emptyParameterTypes(0 To 0) As String
                            If TranslateSimpleRecordInitializer( _
                                translation, catalog, sourceInitializer, _
                                freeBasicType, initializerText, _
                                emptySimpleContext, emptyCallableNames(), 0, _
                                emptyParameterNames(), emptyParameterAliases(), _
                                emptyParameterTypes(), 0, -1) = 0 Then
                                If translation.body.assumeZeroStaticAggregates = 0 OrElse _
                                   CBodyZeroStaticAggregateInitializer( _
                                       translation, sourceInitializer) = 0 Then _
                                    Continue For
                                initializerText = ""
                            End If
                        ElseIf translation.body.assumeZeroStaticAggregates <> 0 AndAlso _
                               Left(LTrim(sourceInitializer), 1) = "{" AndAlso _
                               CBodyZeroStaticAggregateInitializer( _
                                   translation, sourceInitializer) <> 0 Then
                            initializerText = ""
                        ElseIf pointerDepth > 0 AndAlso _
                               GenericNullPointerConstantText(sourceInitializer) <> 0 Then
                            ' Keep the declared pointer type for the initializer;
                            ' the C backend emits its zero without an alias cast.
                            initializerText = "CPtr(" & freeBasicType & ", 0)"
                        Else
                            Dim emptyCallableNames(0 To 0) As String
                            Dim emptyParameterNames(0 To 0) As String
                            Dim emptyParameterAliases(0 To 0) As String
                            Dim emptyParameterTypes(0 To 0) As String
                            Dim hasBooleanOperator As Long
                            Dim hasFunctionCall As Long
                            If TranslateSimpleExpression( _
                                translation, catalog, sourceInitializer, initializerText, _
                                hasBooleanOperator, hasFunctionCall, emptyCallableNames(), _
                                0, emptyParameterNames(), emptyParameterAliases(), _
                                emptyParameterTypes(), 0, freeBasicType) = 0 OrElse _
                               hasFunctionCall <> 0 Then Continue For
                        End If
                    End If
                End If
            End If
            RecordCBodyExternalObjectInContext( _
                translation, catalog, sourceName, sourceName, freeBasicType, _
                arrayCount, CInt(arrayDepth <> 0), isConstObject, _
                isPrivateStatic, initializerText, _
                CInt(reusedStaticName <> "") * -1, isUnsizedArray, _
                arrayRank, arrayDimensions, isGlobalDefinition, pointerDepth, _
                CBodyObjectVolatileMask( _
                    itemTokens(), itemTokenCount, _
                    itemCommonTypeTokenCount, sourceName))
        Next
    Next
End Sub

Private Sub IndexCBodyProceduresFromDeclarations( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
)
    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        If translation.sourceUnit.declarations(declarationIndex).entryKind <> _
           C2FB_DECLARATION_FUNCTION Then Continue For
        RecordCBodyProcedure( _
            translation, catalog, translation.sourceUnit.declarations(declarationIndex))
    Next

    ' Some libc headers expose printf with host-specific restrict typedefs
    ' that the conservative declaration reader cannot fully normalize.
    ' Its variadic C ABI is stable, so keep this known runtime signature.
    Dim printfIndex As Long = CBodyProcedureIndex(translation, "printf")
    If printfIndex < 0 Then
        printfIndex = EnsureC2fbSymbolInContext( _
            translation, "printf", "printf", "printf", GENERIC_SYMBOL_FUNCTION)
        With translation.symbolTable.symbols(printfIndex)
            .body.returnType = "c2fb_c_int"
            .body.parameterTypes = "Const ZString Ptr|"
            .body.parameterCount = 1
            .body.isVariadic = -1
            .body.isDeclared = -1
        End With
    ElseIf translation.symbolTable.symbols(printfIndex).ambiguous <> 0 OrElse _
           translation.symbolTable.symbols(printfIndex).body.isAmbiguous <> 0 Then
        With translation.symbolTable.symbols(printfIndex)
            .body.returnType = "c2fb_c_int"
            .body.parameterTypes = "Const ZString Ptr|"
            .body.parameterCount = 1
            .body.isVariadic = -1
            .body.isStatic = 0
            .ambiguous = 0
            .body.isAmbiguous = 0
        End With
    End If

    ' glibc may expose strlen through several fortified and builtin
    ' declarations, leaving no callable signature even though body lowering
    ' deliberately aliases calls away from FreeBASIC's intrinsic.
    Dim strlenIndex As Long = C2fbSymbolIndexInContext(translation, "strlen")
    If strlenIndex < 0 Then
        strlenIndex = EnsureC2fbSymbolInContext( _
            translation, "strlen", "strlen", "strlen", GENERIC_SYMBOL_FUNCTION)
    End If
    If strlenIndex < 0 Then _
        ReportError("source exceeds the configured procedure limit")
    With translation.symbolTable.symbols(strlenIndex)
        If .body.hasDefinition = 0 Then
            .ambiguous = 0
            .body.isAmbiguous = 0
            .body.returnType = "c2fb_size_t"
            .body.parameterTypes = "Const ZString Ptr|"
            .body.parameterCount = 1
            .body.isVariadic = 0
            .body.isStatic = 0
            .body.linkName = "strlen"
            .body.isDeclared = -1
        End If
    End With
End Sub

/' end of c2fb_symbols.bi '/
