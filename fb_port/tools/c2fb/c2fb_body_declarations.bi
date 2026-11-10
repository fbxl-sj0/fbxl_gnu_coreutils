/'
    Project: C2FB body lowering

    File: c2fb_body_declarations.bi

    Purpose:

        Lower C local declarations and initializers into body-local bindings.

    Responsibilities:

        - Translate local scalar, array, string, and record declarations.
        - Normalize raw local function-pointer arrays to shared callback types.
        - Split comma-separated local declarations with shared token ranges.
        - Validate supported static and nested record initializers.
        - Register local names and types in the current procedure scope.
        - Preserve the first detailed failure for the body rejection report.

    This file intentionally does NOT contain:

        - Statement and control-flow parsing or procedure construction.
        - C source collection, preprocessing, or generated-file output.
'/

Private Function ReadSimpleStaticStringArray( _
    ByVal sourceText As String, ByRef values As String, ByRef byteCount As Long _
) As Long
    values = ""
    byteCount = 0
    Dim position As Long = 1
    Do
        SkipCSpaces(sourceText, position)
        If Mid(sourceText, position, 1) <> Chr(34) Then Return 0
        position += 1
        Dim hasClosingQuote As Long = 0
        While position <= Len(sourceText)
            Dim byteValue As Long = Asc(sourceText, position)
            If byteValue = Asc(Chr(34)) Then
                position += 1
                hasClosingQuote = -1
                Exit While
            ElseIf byteValue = Asc(Chr(92)) Then
                Dim parser As SimpleExpressionParser
                parser.sourceText = sourceText
                parser.position = position
                If ReadSimpleStringEscape(parser, byteValue) = 0 Then Return 0
                position = parser.position
            Else
                If byteValue = 0 OrElse byteValue = 10 OrElse byteValue = 13 Then Return 0
                position += 1
            End If
            If byteCount >= 65534 Then Return 0
            If values <> "" Then values &= ", "
            values &= Trim(Str(byteValue))
            byteCount += 1
        Wend
        If hasClosingQuote = 0 Then Return 0
        SkipCSpaces(sourceText, position)
        If Mid(sourceText, position, 1) <> Chr(34) Then Exit Do
    Loop
    If values <> "" Then values &= ", "
    values &= "0" ' C string arrays include the terminating NUL byte.
    byteCount += 1
    Return -1
End Function


Private Function ReadSimpleCharArrayStringInitializer( _
    ByVal sourceText As String, ByVal arrayCount As Long, _
    ByRef values As String, ByRef valueCount As Long _
) As Long
    values = ""
    valueCount = 0
    If arrayCount < 1 OrElse arrayCount > MAX_SIMPLE_ARRAY_COUNT Then Return 0

    Dim byteCount As Long
    If ReadSimpleStaticStringArray(sourceText, values, byteCount) = 0 Then Return 0
    If byteCount < 1 OrElse byteCount - 1 > arrayCount Then Return 0

    If byteCount > arrayCount Then
        ' C permits a fixed character array to omit only the literal's final NUL.
        Dim elements() As String
        Dim elementCount As Long
        If SplitSimpleCList(values, elements(), elementCount) = 0 OrElse _
           elementCount <> byteCount Then Return 0
        valueCount = elementCount - 1
        values = ""
        For elementIndex As Long = 0 To valueCount - 1
            If elementIndex > 0 Then values &= ", "
            values &= elements(elementIndex)
        Next
    Else
        valueCount = byteCount
    End If
    Return -1
End Function


Private Function ReadSimpleStaticStringMatrix( _
    ByVal initializerText As String, ByVal rowWidth As Long, _
    ByRef values As String, ByRef rowCount As Long, _
    ByRef byteCount As Long _
) As Long
    values = ""
    rowCount = 0
    byteCount = 0
    initializerText = Trim(initializerText)
    If rowWidth < 1 OrElse Left(initializerText, 1) <> "{" OrElse _
       Right(initializerText, 1) <> "}" Then Return 0

    Dim initialText As String = Trim(Mid( _
        initializerText, 2, Len(initializerText) - 2))
    If Right(initialText, 1) = "," Then _
        initialText = RTrim(Left(initialText, Len(initialText) - 1))
    Dim rows() As String
    If SplitSimpleCList(initialText, rows(), rowCount) = 0 OrElse _
       rowCount < 1 OrElse rowCount > MAX_SIMPLE_ARRAY_COUNT OrElse _
       rowCount > MAX_SIMPLE_ARRAY_COUNT \ rowWidth Then Return 0

    For rowIndex As Long = 0 To rowCount - 1
        Dim rowValues As String
        Dim rowByteCount As Long
        If ReadSimpleStaticStringArray( _
            Trim(rows(rowIndex)), rowValues, rowByteCount) = 0 OrElse _
           rowByteCount > rowWidth Then Return 0
        If values <> "" Then values &= ", "
        values &= rowValues
        For columnIndex As Long = rowByteCount To rowWidth - 1
            values &= ", 0"
        Next
    Next
    byteCount = rowCount * rowWidth
    Return -1
End Function



' Local enum values use the same bounded integer grammar as generic headers.
' Resolve visible body constants first so a local name can shadow a header enum.
Private Function EvaluateSimpleBodyEnumIntegerExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, _
    locals() As SimpleLocalVariable, ByVal localCount As Long, _
    parameterNames() As String, ByVal parameterCount As Long, _
    ByRef integerValue As Long _
) As Long
    Dim numericExpression As String
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceExpression) AndAlso _
                  IsIdentifierPart(Asc(sourceExpression, position)) <> 0
                position += 1
            Wend
            Dim sourceName As String = Mid( _
                sourceExpression, tokenStart, position - tokenStart)
            Dim visibleSymbol As Long = -1
            For symbolIndex As Long = parameterCount - 1 To 0 Step -1
                If parameterNames(symbolIndex) = sourceName Then
                    visibleSymbol = symbolIndex
                    Exit For
                End If
            Next
            If visibleSymbol >= 0 Then
                Dim localIndex As Long = -1
                For candidateIndex As Long = localCount - 1 To 0 Step -1
                    If locals(candidateIndex).name = sourceName Then
                        localIndex = candidateIndex
                        Exit For
                    End If
                Next
                If localIndex < 0 OrElse _
                   locals(localIndex).isIntegerConstant = 0 Then Return 0
                numericExpression &= Trim(Str(locals(localIndex).integerValue))
            Else
                Dim enumIndex As Long = _
                    GenericEnumMemberIndexInContext(translation, sourceName)
                If enumIndex < 0 OrElse _
                   translation.genericC.header.enumMembers( _
                       enumIndex).integerValueKnown = 0 Then Return 0
                numericExpression &= Trim(Str( _
                    translation.genericC.header.enumMembers( _
                        enumIndex).integerValue))
            End If
        ElseIf currentByte >= Asc("0") AndAlso currentByte <= Asc("9") Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceExpression) AndAlso _
                  IsIdentifierPart(Asc(sourceExpression, position)) <> 0
                position += 1
            Wend
            numericExpression &= Mid( _
                sourceExpression, tokenStart, position - tokenStart)
        Else
            numericExpression &= Chr(currentByte)
            position += 1
        End If
    Wend

    Dim parser As SimpleArrayBoundParser
    parser.sourceText = numericExpression
    parser.position = 1
    Dim value As LongInt
    If ReadSimpleArrayBoundShift(parser, value, 0) = 0 Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position <= Len(parser.sourceText) OrElse _
       value < -MAX_GENERIC_ARRAY_BOUND_VALUE OrElse _
       value > MAX_GENERIC_ARRAY_BOUND_VALUE Then Return 0
    integerValue = CLng(value)
    Return -1
End Function


' Local enums have block scope but no runtime storage. Give each enumerator a
' private compile-time alias and retain its value for later members.
Private Function TranslateSimpleLocalEnumDefinition( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, ByRef outputText As String, _
    ByRef context As SimpleBodyContext, _
    locals() As SimpleLocalVariable, ByRef localCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByRef symbolCount As Long _
) As Long
    outputText = ""
    If translation.target.profile <> C2FB_TARGET_GENERIC Then Return 0

    statementText = Trim(statementText)
    If Left(statementText, Len("enum")) <> "enum" OrElse _
       (Len(statementText) > Len("enum") AndAlso _
        IsIdentifierPart(Asc(statementText, Len("enum") + 1)) <> 0) Then _
        Return 0

    Dim position As Long = Len("enum") + 1
    SkipCSpaces(statementText, position)
    If position <= Len(statementText) AndAlso _
       Asc(statementText, position) <> Asc("{") Then
        If IsIdentifierStart(Asc(statementText, position)) = 0 Then Return 0
        While position <= Len(statementText) AndAlso _
              IsIdentifierPart(Asc(statementText, position)) <> 0
            position += 1
        Wend
        SkipCSpaces(statementText, position)
    End If
    If position > Len(statementText) OrElse _
       Asc(statementText, position) <> Asc("{") Then Return 0
    Dim openingBrace As Long = position
    Dim closingBrace As Long = position
    If ScanSimpleExpressionGroup( _
        statementText, closingBrace, Asc("{"), Asc("}")) = 0 Then Return 0
    Dim enumBody As String = Mid( _
        statementText, openingBrace + 1, closingBrace - openingBrace - 2)
    position = closingBrace
    SkipCSpaces(statementText, position)
    Dim localObjectName As String
    Dim localObjectInitializer As String
    If position <= Len(statementText) AndAlso _
       Asc(statementText, position) = Asc(";") Then
        position += 1
    ElseIf position <= Len(statementText) Then
        Dim declaratorText As String = Trim(Mid(statementText, position))
        If Right(declaratorText, 1) = ";" Then _
            declaratorText = Trim(Left(declaratorText, Len(declaratorText) - 1))
        Dim objectInitializerEquals As Long = _
            FindSimpleAssignmentEquals(declaratorText)
        If objectInitializerEquals > 0 Then
            localObjectName = Trim(Left( _
                declaratorText, objectInitializerEquals - 1))
            localObjectInitializer = Trim(Mid( _
                declaratorText, objectInitializerEquals + 1))
            If localObjectInitializer = "" Then Return 0
        Else
            localObjectName = declaratorText
        End If
        If IsIdentifierToken(localObjectName) = 0 Then Return 0
        position = Len(statementText) + 1
    End If
    SkipCSpaces(statementText, position)
    If position <= Len(statementText) Then Return 0

    Dim enumParts() As String
    Dim enumPartCount As Long
    If SplitSimpleCList( _
        enumBody, enumParts(), enumPartCount, -1) = 0 OrElse _
       enumPartCount < 1 OrElse enumPartCount > MAX_SIMPLE_VARIABLES Then _
        Return 0

    Dim scopeStart As Long = 0
    If context.scopeDepth > 0 Then _
        scopeStart = context.scopeSymbols(context.scopeDepth - 1)
    Dim previousValue As Long = 0
    Dim previousValueKnown As Long = -1
    Dim previousAlias As String
    Dim callableNames(0 To 0) As String
    For memberIndex As Long = 0 To enumPartCount - 1
        Dim memberText As String = Trim(enumParts(memberIndex))
        Dim equalsPosition As Long = FindSimpleAssignmentEquals(memberText)
        Dim memberNameText As String = memberText
        If equalsPosition > 0 Then _
            memberNameText = Trim(Left(memberText, equalsPosition - 1))

        Dim memberTokens() As String
        Dim memberTokenCount As Long
        TokenizeCDeclaration( _
            memberNameText, memberTokens(), memberTokenCount)
        If memberTokenCount <> 1 OrElse _
           IsIdentifierToken(memberTokens(0)) = 0 Then Return 0
        Dim memberName As String = memberTokens(0)
        For symbolIndex As Long = scopeStart To symbolCount - 1
            If parameterNames(symbolIndex) = memberName Then Return 0
        Next

        Dim value As Long
        Dim valueKnown As Long = 0
        Dim freeBasicValue As String
        If equalsPosition > 0 Then
            Dim valueExpression As String = Trim( _
                Mid(memberText, equalsPosition + 1))
            If valueExpression = "" Then Return 0
            If EvaluateSimpleBodyEnumIntegerExpression( _
                translation, valueExpression, locals(), localCount, _
                parameterNames(), symbolCount, value) <> 0 Then
                valueKnown = -1
                freeBasicValue = Trim(Str(value))
            Else
                Dim hasBooleanOperator As Long
                Dim hasFunctionCall As Long
                If TranslateSimpleExpression( _
                    translation, catalog, valueExpression, freeBasicValue, _
                    hasBooleanOperator, hasFunctionCall, callableNames(), 0, _
                    parameterNames(), parameterAliases(), parameterTypes(), _
                    symbolCount, "c2fb_c_int", 0, -1) = 0 OrElse _
                   hasFunctionCall <> 0 Then Return 0
            End If
        ElseIf memberIndex = 0 Then
            value = 0
            valueKnown = -1
            freeBasicValue = "0"
        ElseIf previousValueKnown <> 0 Then
            If previousValue >= MAX_GENERIC_ARRAY_BOUND_VALUE Then Return 0
            value = previousValue + 1
            valueKnown = -1
            freeBasicValue = Trim(Str(value))
        Else
            freeBasicValue = previousAlias & " + 1"
        End If

        If context.localSerial >= MAX_SIMPLE_VARIABLES OrElse _
           localCount >= MAX_SIMPLE_VARIABLES OrElse _
           symbolCount >= MAX_SIMPLE_VARIABLES Then Return 0
        Dim aliasName As String = "local" & Trim(Str(context.localSerial))
        context.localSerial += 1
        context.declarations &= "    Const " & aliasName & _
            " As c2fb_c_int = " & freeBasicValue & Chr(10)
        context.readOnlyAliases &= "|" & aliasName & "|"
        locals(localCount).name = memberName
        locals(localCount).typeName = "c2fb_c_int"
        locals(localCount).isConst = -1
        locals(localCount).sizeofBytes = CLng(SizeOf(Long))
        locals(localCount).hasKnownSize = -1
        locals(localCount).isIntegerConstant = valueKnown
        locals(localCount).integerValue = value
        localCount += 1
        parameterNames(symbolCount) = memberName
        parameterAliases(symbolCount) = aliasName
        parameterTypes(symbolCount) = "c2fb_c_int"
        symbolCount += 1
        previousValue = value
        previousValueKnown = valueKnown
        previousAlias = aliasName
    Next

    Dim localObjectInitializerOutput As String
    If localObjectName <> "" Then
        For symbolIndex As Long = scopeStart To symbolCount - 1
            If parameterNames(symbolIndex) = localObjectName Then Return 0
        Next
        If context.localSerial >= MAX_SIMPLE_VARIABLES OrElse _
           localCount >= MAX_SIMPLE_VARIABLES OrElse _
           symbolCount >= MAX_SIMPLE_VARIABLES Then Return 0
        Dim localAlias As String = "local" & Trim(Str(context.localSerial))
        context.localSerial += 1
        context.declarations &= "    Dim " & localAlias & _
            " As c2fb_c_int" & Chr(10)
        locals(localCount).name = localObjectName
        locals(localCount).typeName = "c2fb_c_int"
        locals(localCount).isConst = 0
        locals(localCount).sizeofBytes = CLng(SizeOf(Long))
        locals(localCount).hasKnownSize = -1
        locals(localCount).isIntegerConstant = 0
        locals(localCount).integerValue = 0
        localCount += 1
        parameterNames(symbolCount) = localObjectName
        parameterAliases(symbolCount) = localAlias
        parameterTypes(symbolCount) = "c2fb_c_int"
        symbolCount += 1
        If localObjectInitializer <> "" Then
            Dim initializerIntegerValue As Long
            If EvaluateSimpleBodyEnumIntegerExpression( _
                translation, localObjectInitializer, locals(), localCount, _
                parameterNames(), symbolCount, initializerIntegerValue) <> 0 Then
                localObjectInitializerOutput = Trim(Str(initializerIntegerValue))
            Else
                Dim initializerHasBoolean As Long
                Dim initializerHasCall As Long
                If TranslateSimpleExpression( _
                    translation, catalog, localObjectInitializer, _
                    localObjectInitializerOutput, initializerHasBoolean, _
                    initializerHasCall, callableNames(), 0, parameterNames(), _
                    parameterAliases(), parameterTypes(), symbolCount, _
                    "c2fb_c_int", 0, -1) = 0 OrElse _
                   initializerHasCall <> 0 Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-local-enum-object-initializer", _
                        "unsupported local enum object initializer: " & _
                        localObjectInitializer)
                    Return 0
                End If
            End If
            localObjectInitializerOutput = localAlias & " = " & _
                localObjectInitializerOutput
        End If
    End If
    outputText = "' C local enum constants"
    If localObjectInitializerOutput <> "" Then _
        outputText &= Chr(10) & localObjectInitializerOutput
    Return -1
End Function


Private Function CBodySourceRecordKindInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceRecord As String _
) As C2fbRecordKind
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .recordKind = C2FB_RECORD_KIND_NONE Then Continue For
            If .recordTag = sourceRecord OrElse _
               .recordAlias = sourceRecord Then Return .recordKind
        End With
    Next
    For bindingIndex As Long = 0 To translation.body.recordBindingCount - 1
        With translation.body.recordBindings(bindingIndex)
            ' Source-unit anonymous aggregates use owner.field keys.
            If (.isGenerated <> 0 OrElse InStr(.sourceName, ".") <> 0) AndAlso _
               .sourceName = sourceRecord Then _
                Return .recordKind
        End With
    Next
    Return C2FB_RECORD_KIND_NONE
End Function

Private Function EvaluateCBodyFixedArrayBound( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef arrayCount As Long _
) As Long
    arrayCount = 0
    If EvaluateSimpleArrayBound( _
        sourceExpression, arrayCount, MAX_SIMPLE_ARRAY_COUNT) <> 0 Then _
        Return -1

    Dim normalizedExpression As String
    If NormalizeGenericArrayBoundSizeof( _
        translation, sourceExpression, normalizedExpression) <> 0 AndAlso _
       EvaluateSimpleArrayBound( _
        normalizedExpression, arrayCount, MAX_SIMPLE_ARRAY_COUNT) <> 0 Then _
        Return -1

    If EvaluateGenericHeaderArrayBound( _
        translation, sourceExpression, arrayCount, _
        MAX_SIMPLE_ARRAY_COUNT) <> 0 Then Return -1
    arrayCount = 0
    Return 0
End Function

Private Function TranslateCBodyFixedArrayBoundToFreeBasic( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceExpression As String, _
    ByRef freeBasicExpression As String _
) As Long
    freeBasicExpression = ""
    If InStr(LCase(sourceExpression), "sizeof") = 0 Then Return 0

    Dim callableNames(0 To 0) As String
    Dim parameterNames(0 To 0) As String
    Dim parameterAliases(0 To 0) As String
    Dim parameterTypes(0 To 0) As String
    Dim hasBooleanOperator As Long
    Dim hasFunctionCall As Long
    If TranslateSimpleExpression( _
        translation, catalog, sourceExpression, freeBasicExpression, _
        hasBooleanOperator, hasFunctionCall, callableNames(), 0, _
        parameterNames(), parameterAliases(), parameterTypes(), 0, _
        "c2fb_size_t", 0, -1) = 0 OrElse hasFunctionCall <> 0 Then
        freeBasicExpression = ""
        Return 0
    End If
    Return -1
End Function

Private Function RegisterCBodyAnonymousRecord( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal recordBody As String, _
    ByRef generatedRecordName As String, _
    ByVal recordKind As C2fbRecordKind = C2FB_RECORD_STRUCT, _
    ByVal generatedNamePrefix As String = "c2fb_local_record_", _
    ByVal useStaticRecordSerial As Long = 0, _
    ByVal sourceRecordTag As String = "" _
) As Long
    generatedRecordName = ""
    If (recordKind <> C2FB_RECORD_STRUCT AndAlso _
        recordKind <> C2FB_RECORD_UNION) OrElse _
       Trim(recordBody) = "" OrElse InStr(recordBody, "{") <> 0 OrElse _
       InStr(recordBody, "}") <> 0 Then Return 0
    Dim recordSerial As Long
    If useStaticRecordSerial <> 0 Then
        recordSerial = translation.body.staticRecordSerial
    Else
        recordSerial = translation.body.localRecordSerial
    End If
    If recordSerial >= MAX_SIMPLE_VARIABLES Then Return 0

    Dim sourceRecordName As String = generatedNamePrefix & Trim(Str(recordSerial))
    For i As Long = 0 To translation.body.recordBindingCount - 1
        If LCase(translation.body.recordBindings(i).sourceName) = _
           LCase(sourceRecordName) Then Return 0
    Next
    For i As Long = 0 To catalog.bodyFieldCount - 1
        If LCase(catalog.bodyFields(i).ownerName) = _
           LCase(sourceRecordName) Then Return 0
    Next

    Dim savedRecordFieldCount As Long = translation.body.recordFieldCount
    Dim savedRecordBindingCount As Long = translation.body.recordBindingCount
    Dim savedBodyFieldCount As Long = catalog.bodyFieldCount
    Dim localDeclaration As C2fbDeclarationModel
    localDeclaration.entryKind = C2FB_DECLARATION_RECORD
    localDeclaration.recordKind = recordKind
    localDeclaration.recordTag = sourceRecordName
    localDeclaration.recordBody = recordBody
    BuildC2fbRecordFieldSources(localDeclaration)
    If localDeclaration.recordFieldsComplete = 0 OrElse _
       localDeclaration.recordFieldCount = 0 Then Return 0
    If RecordCBodyFieldsFromModel( _
        translation, catalog, sourceRecordName, localDeclaration, 0, 0) = 0 Then
        translation.body.recordFieldCount = savedRecordFieldCount
        RebuildCBodyRecordFieldIndexes(translation)
        translation.body.recordBindingCount = savedRecordBindingCount
        Return 0
    End If

    Dim registeredFieldCount As Long = _
        translation.body.recordFieldCount - savedRecordFieldCount
    ' A C field declaration may contain several comma-separated declarators,
    ' so the generated field count can exceed the number of semicolon-delimited
    ' declarations collected from the record body.
    If registeredFieldCount <= 0 Then
        translation.body.recordFieldCount = savedRecordFieldCount
        RebuildCBodyRecordFieldIndexes(translation)
        translation.body.recordBindingCount = savedRecordBindingCount
        Return 0
    End If

    Dim recordAccepted As Long = -1
    For fieldIndex As Long = savedRecordFieldCount To _
        translation.body.recordFieldCount - 1
        With translation.body.recordFields(fieldIndex)
            If .ownerName <> sourceRecordName OrElse _
               IsIdentifierToken(.name) = 0 OrElse .bitWidth >= 0 Then
                recordAccepted = 0
                Exit For
            End If
            For priorField As Long = savedRecordFieldCount To fieldIndex - 1
                If LCase(translation.body.recordFields(priorField).name) = _
                   LCase(.name) Then
                    recordAccepted = 0
                    Exit For
                End If
            Next
            If recordAccepted = 0 Then Exit For

            Dim fieldType As String = CBodyFieldType( _
                translation, catalog, fieldIndex)
            If fieldType = "" Then
                recordAccepted = 0
                Exit For
            End If
            Dim storedFieldType As String = fieldType
            If .isArray <> 0 Then
                Dim arrayCount As Long
                If .isFlexibleArray <> 0 Then
                    ' A flexible C tail needs an explicit storage extent in
                    ' FreeBASIC. Keep the layout choice source-scoped so the
                    ' caller can verify it against the active C ABI.
                    arrayCount = UseGenericArraySizeOverrideInPolicy( _
                        translation.genericC.policy, .name, sourceRecordTag)
                    If arrayCount > 0 Then _
                        .arrayBound = Trim(Str(arrayCount))
                End If
                ' C permits target-ABI sizeof expressions in a local record's
                ' fixed array bound. Use the same type-aware evaluator as
                ' header records when the integer-only path cannot resolve it.
                If EvaluateCBodyFixedArrayBound( _
                    translation, .arrayBound, arrayCount) = 0 OrElse _
                   arrayCount < 1 OrElse arrayCount > MAX_SIMPLE_ARRAY_COUNT Then
                    If TranslateCBodyFixedArrayBoundToFreeBasic( _
                        translation, catalog, .arrayBound, _
                        .freeBasicArrayCountExpression) = 0 Then
                        recordAccepted = 0
                        Exit For
                    End If
                End If
                If IsCBodyCallbackTypeInContext( _
                    translation, fieldType) = 0 Then
                    storedFieldType = SimplePointeeType(fieldType)
                End If
                If storedFieldType = "" Then
                    recordAccepted = 0
                    Exit For
                End If
            Else
                Dim nestedRecord As String = CBodyRecordName( _
                    translation, catalog, fieldType)
                If SimpleArithmeticKind(catalog, fieldType) = 0 AndAlso _
                   InStr(fieldType, " Ptr") = 0 AndAlso _
                   IsCBodyCallbackTypeInContext(translation, fieldType) = 0 AndAlso _
                   (nestedRecord = "" OrElse _
                    CBodyRecordSizeIsKnown( _
                        translation, catalog, nestedRecord) = 0) Then
                    Dim scalarStorageSize As Long
                    If GenericArrayBoundTypeSizeInContext( _
                        translation, fieldType, scalarStorageSize) = 0 OrElse _
                       scalarStorageSize <= 0 Then
                        recordAccepted = 0
                        Exit For
                    End If
                End If
            End If

            If catalog.bodyFieldCount >= MAX_C2FB_BODY_CATALOG_FIELDS Then _
                ReportError("FreeBASIC record fields exceed the configured limit")
            If catalog.bodyFieldCount > UBound(catalog.bodyFields) Then _
                ReDim Preserve catalog.bodyFields( _
                    0 To UBound(catalog.bodyFields) * 2 + 1)
            With catalog.bodyFields(catalog.bodyFieldCount)
                .ownerName = sourceRecordName
                .name = translation.body.recordFields(fieldIndex).freeBasicName
                If .name = "" Then _
                    .name = translation.body.recordFields(fieldIndex).name
                .typeName = storedFieldType
                .isArray = translation.body.recordFields(fieldIndex).isArray
                .freeBasicArrayCountExpression = _
                    translation.body.recordFields( _
                        fieldIndex).freeBasicArrayCountExpression
                .isUnionMember = 0
                .headerName = ""
            End With
            catalog.bodyFieldCount += 1
            IndexC2fbBodyField(catalog, catalog.bodyFieldCount - 1)
        End With
        If recordAccepted = 0 Then Exit For
    Next
    If recordAccepted = 0 Then
        translation.body.recordFieldCount = savedRecordFieldCount
        RebuildCBodyRecordFieldIndexes(translation)
        translation.body.recordBindingCount = savedRecordBindingCount
        catalog.bodyFieldCount = savedBodyFieldCount
        RebuildC2fbBodyFieldIndex(catalog)
        Return 0
    End If

    If translation.body.recordBindingCount >= _
       MAX_C2FB_BODY_RECORD_BINDINGS Then _
        ReportError("generated anonymous records exceed the configured limit")
    If translation.body.recordBindingCount > UBound(translation.body.recordBindings) Then _
        ReDim Preserve translation.body.recordBindings( _
            0 To UBound(translation.body.recordBindings) * 2 + 1)
    With translation.body.recordBindings(translation.body.recordBindingCount)
        .sourceName = sourceRecordName
        .fbName = sourceRecordName
        .recordKind = recordKind
        .isGenerated = -1
    End With
    translation.body.recordBindingCount += 1
    If useStaticRecordSerial <> 0 Then
        translation.body.staticRecordSerial += 1
    Else
        translation.body.localRecordSerial += 1
    End If
    generatedRecordName = sourceRecordName
    Return -1
End Function

Private Function SimpleInlineCallbackMatchesBodyType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal inlineType As String, ByVal callbackIndex As Long _
) As Long
    If callbackIndex < 0 OrElse _
       translation.body.callbacks(callbackIndex).isVariadic <> 0 Then Return 0
    inlineType = Trim(inlineType)
    Dim isFunction As Long = CInt(Left(inlineType, 9) = "Function ")
    Dim isSub As Long = CInt(Left(inlineType, 4) = "Sub ")
    If isFunction = 0 AndAlso isSub = 0 Then Return 0

    Dim opening As Long = InStr(inlineType, "(")
    If opening = 0 Then Return 0
    Dim nesting As Long = 0
    Dim closing As Long = 0
    For position As Long = opening To Len(inlineType)
        Select Case Mid(inlineType, position, 1)
        Case "("
            nesting += 1
        Case ")"
            nesting -= 1
            If nesting < 0 Then Return 0
            If nesting = 0 Then
                closing = position
                Exit For
            End If
        End Select
    Next
    If closing = 0 Then Return 0

    Dim returnType As String
    Dim suffix As String = Trim(Mid(inlineType, closing + 1))
    If isFunction <> 0 Then
        If LCase(Left(suffix, 3)) <> "as " Then Return 0
        returnType = Trim(Mid(suffix, 4))
    Else
        If suffix <> "" Then Return 0
        returnType = "Void"
    End If
    With translation.body.callbacks(callbackIndex)
        If CBodyCallbackTypesCompatibleInContext( _
            translation, catalog, returnType, .returnType, 0) = 0 Then Return 0
        If Trim(Mid(inlineType, opening + 1, closing - opening - 1)) = "" Then _
            Return CInt(.parameterCount = 0) * -1
        If .parameterCount = 0 Then Return 0

        Dim parameterStart As Long = opening + 1
        Dim parameterIndex As Long = 0
        nesting = 0
        For position As Long = opening + 1 To closing
            Dim isParameterEnd As Long = 0
            If position = closing Then
                isParameterEnd = -1
            Else
                Select Case Mid(inlineType, position, 1)
                Case "("
                    nesting += 1
                Case ")"
                    nesting -= 1
                    If nesting < 0 Then Return 0
                Case ","
                    If nesting = 0 Then isParameterEnd = -1
                End Select
            End If
            If isParameterEnd = 0 Then Continue For

            Dim parameterDeclaration As String = Trim(Mid( _
                inlineType, parameterStart, position - parameterStart))
            Dim asPosition As Long = InStr(LCase(parameterDeclaration), " as ")
            If asPosition = 0 OrElse parameterIndex >= .parameterCount Then Return 0
            Dim parameterType As String = Trim(Mid(parameterDeclaration, asPosition + 4))
            Dim sourceParameterType As String = CBodyCallbackParameterTypeInContext( _
                translation, .fbType, parameterIndex)
            If CBodyCallbackTypesCompatibleInContext( _
                translation, catalog, parameterType, sourceParameterType, 0) = 0 Then _
                Return 0
            parameterIndex += 1
            parameterStart = position + 1
        Next
        Return CInt(parameterIndex = .parameterCount) * -1
    End With
End Function

Private Function ConvertSimpleRecordInitializerFieldStorage( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceRecord As String, ByVal fieldName As String, _
    ByVal fieldType As String, ByVal fbFieldIndex As Long, _
    ByRef fieldValue As String, _
    ByRef context As SimpleBodyContext _
) As Long
    If fbFieldIndex < 0 Then Return 0
    Dim storedFieldType As String = NormalizeFbBodyType( _
        catalog, catalog.bodyFields(fbFieldIndex).typeName)
    Dim convertedFieldType As String = NormalizeFbBodyType( _
        catalog, fieldType)
    If storedFieldType = convertedFieldType Then Return -1

    Dim storedCallbackIndex As Long = _
        CBodyCallbackIndexInContext(translation, storedFieldType)
    Dim sourceCallbackIndex As Long = _
        CBodyCallbackIndexInContext(translation, fieldType)
    If storedCallbackIndex >= 0 OrElse sourceCallbackIndex >= 0 OrElse _
       Left(storedFieldType, 9) = "Function " OrElse _
       Left(storedFieldType, 4) = "Sub " Then
        If storedCallbackIndex >= 0 AndAlso sourceCallbackIndex >= 0 Then
            With translation.body.callbacks(storedCallbackIndex)
                If .parameterCount = translation.body.callbacks( _
                    sourceCallbackIndex).parameterCount AndAlso _
                   .isVariadic = translation.body.callbacks( _
                    sourceCallbackIndex).isVariadic AndAlso _
                   CBodyCallbackTypesCompatibleInContext( _
                       translation, catalog, .returnType, _
                       translation.body.callbacks( _
                           sourceCallbackIndex).returnType, 0) <> 0 Then
                    Dim parametersMatch As Long = -1
                    For parameterIndex As Long = 0 To .parameterCount - 1
                        If CBodyCallbackTypesCompatibleInContext( _
                            translation, catalog, _
                            CBodyCallbackParameterTypeInContext( _
                                translation, .fbType, parameterIndex), _
                            CBodyCallbackParameterTypeInContext( _
                                translation, translation.body.callbacks( _
                                    sourceCallbackIndex).fbType, _
                                parameterIndex), 0) = 0 Then
                            parametersMatch = 0
                            Exit For
                        End If
                    Next
                    If parametersMatch <> 0 Then Return -1
                End If
            End With
        End If
        If sourceCallbackIndex >= 0 AndAlso _
           storedFieldType = translation.body.callbacks( _
               sourceCallbackIndex).declaration Then Return -1
        If sourceCallbackIndex >= 0 AndAlso _
           SimpleInlineCallbackMatchesBodyType( _
               translation, catalog, storedFieldType, sourceCallbackIndex) <> 0 Then _
            Return -1
        If storedCallbackIndex >= 0 AndAlso _
           fieldType = translation.body.callbacks( _
               storedCallbackIndex).declaration Then Return -1
        If storedCallbackIndex >= 0 AndAlso _
           SimpleInlineCallbackMatchesBodyType( _
               translation, catalog, fieldType, storedCallbackIndex) <> 0 Then _
            Return -1
        RecordSimpleBodyFailure( _
            context, "static-record-callback-type-mismatch", _
            "static record callback field types do not match " & _
            sourceRecord & "." & fieldName)
        Return 0
    End If

    If InStr(storedFieldType, " Ptr") <> 0 Then
        fieldValue = "CPtr(" & storedFieldType & ", " & fieldValue & ")"
        Return -1
    End If
    If SimpleArithmeticKind(catalog, storedFieldType) > 0 AndAlso _
       SimpleArithmeticKind(catalog, fieldType) > 0 Then
        fieldValue = "Cast(" & storedFieldType & ", " & fieldValue & ")"
        Return -1
    End If

    RecordSimpleBodyFailure( _
        context, "static-record-field-storage-mismatch", _
        "static record field storage mismatch " & sourceRecord & "." & _
        fieldName & ": C type=" & fieldType & _
        ", FreeBASIC type=" & storedFieldType)
    Return 0
End Function

Private Function ParseSimpleCMemberDesignator( _
    ByVal initializerText As String, _
    ByRef fieldName As String, _
    ByRef fieldInitializer As String _
) As Long
    fieldName = ""
    fieldInitializer = ""
    initializerText = Trim(initializerText)
    If Len(initializerText) < 4 OrElse Left(initializerText, 1) <> "." Then Return 0
    Dim pathSegments(0 To MAX_TYPE_WORDS - 1) As String
    Dim pathSegmentCount As Long = 0
    Dim position As Long = 1
    Dim foundInitializer As Long = 0
    While position <= Len(initializerText)
        If Asc(initializerText, position) <> Asc(".") Then Return 0
        position += 1
        SkipCSpaces(initializerText, position)
        If position > Len(initializerText) OrElse _
           IsIdentifierStart(Asc(initializerText, position)) = 0 OrElse _
           pathSegmentCount >= MAX_TYPE_WORDS Then Return 0
        Dim nameStart As Long = position
        position += 1
        While position <= Len(initializerText) AndAlso _
              IsIdentifierPart(Asc(initializerText, position)) <> 0
            position += 1
        Wend
        pathSegments(pathSegmentCount) = _
            Mid(initializerText, nameStart, position - nameStart)
        pathSegmentCount += 1
        SkipCSpaces(initializerText, position)
        If position > Len(initializerText) Then Return 0
        If Asc(initializerText, position) = Asc("=") Then
            position += 1
            fieldInitializer = Trim(Mid(initializerText, position))
            foundInitializer = -1
            Exit While
        ElseIf Asc(initializerText, position) <> Asc(".") Then
            Return 0
        End If
    Wend
    If foundInitializer = 0 OrElse pathSegmentCount = 0 OrElse _
       fieldInitializer = "" Then Return 0

    fieldName = pathSegments(0)
    For pathIndex As Long = pathSegmentCount - 1 To 1 Step -1
        fieldInitializer = "{ ." & pathSegments(pathIndex) & " = " & _
            fieldInitializer & " }"
    Next
    Return -1
End Function

Private Function SimpleCMemberDesignatorPath( _
    ByVal initializerText As String, ByRef pathText As String _
) As Long
    pathText = ""
    initializerText = Trim(initializerText)
    If Left(initializerText, 1) <> "{" OrElse _
       Right(initializerText, 1) <> "}" Then Return 0
    Dim values() As String
    Dim valueCount As Long
    If SplitSimpleCList( _
        Trim(Mid(initializerText, 2, Len(initializerText) - 2)), _
        values(), valueCount) = 0 OrElse valueCount <> 1 Then Return 0
    Dim fieldName As String
    Dim fieldInitializer As String
    If ParseSimpleCMemberDesignator( _
        values(0), fieldName, fieldInitializer) = 0 Then Return 0
    Dim assignmentPosition As Long = FindSimpleAssignmentEquals(values(0))
    If assignmentPosition <= 1 Then Return 0
    Dim pathTokens() As String
    Dim pathTokenCount As Long
    TokenizeCDeclaration( _
        Trim(Left(values(0), assignmentPosition - 1)), _
        pathTokens(), pathTokenCount)
    If pathTokenCount <= 0 Then Return 0
    For tokenIndex As Long = 0 To pathTokenCount - 1
        pathText &= Chr(1) & pathTokens(tokenIndex)
    Next
    Return -1
End Function

' Dropping an overridden initializer is safe only when its value cannot call
' code or read a variable; this subset keeps overrides free of side effects.
Private Function IsIdentifierFreeInitializer(ByVal initializerText As String) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(initializerText, tokens(), tokenCount)
    If tokenCount <= 0 Then Return 0
    For tokenIndex As Long = 0 To tokenCount - 1
        If IsIdentifierToken(tokens(tokenIndex)) <> 0 Then Return 0
    Next
    Return -1
End Function

Private Function MergeSimpleCMemberDesignatorInitializers( _
    ByVal firstText As String, ByVal secondText As String, _
    ByRef mergedText As String, ByVal depth As Long = 0, _
    ByVal allowLiteralOverrides As Long = 0 _
) As Long
    mergedText = ""
    If depth >= MAX_BODY_NESTING Then Return 0
    firstText = Trim(firstText)
    secondText = Trim(secondText)
    If Left(firstText, 1) <> "{" OrElse Right(firstText, 1) <> "}" OrElse _
       Left(secondText, 1) <> "{" OrElse Right(secondText, 1) <> "}" Then Return 0

    Dim firstBody As String = Trim(Mid(firstText, 2, Len(firstText) - 2))
    Dim secondBody As String = Trim(Mid(secondText, 2, Len(secondText) - 2))
    If firstBody = "" OrElse secondBody = "" Then Return 0
    Dim initializerLists(0 To 1) As String
    initializerLists(0) = firstBody
    initializerLists(1) = secondBody

    Dim fieldNames(0 To MAX_TYPE_WORDS - 1) As String
    Dim fieldValues(0 To MAX_TYPE_WORDS - 1) As String
    Dim fieldCount As Long = 0
    For listIndex As Long = 0 To 1
        Dim values() As String
        Dim valueCount As Long
        If SplitSimpleCList( _
            initializerLists(listIndex), values(), valueCount) = 0 Then Return 0
        For valueIndex As Long = 0 To valueCount - 1
            Dim fieldName As String
            Dim fieldInitializer As String
            If ParseSimpleCMemberDesignator( _
                values(valueIndex), fieldName, fieldInitializer) = 0 Then Return 0
            Dim existingField As Long = -1
            For fieldIndex As Long = 0 To fieldCount - 1
                If fieldNames(fieldIndex) = fieldName Then
                    existingField = fieldIndex
                    Exit For
                End If
            Next
            If existingField >= 0 Then
                Dim nestedInitializer As String
                If Left(Trim(fieldValues(existingField)), 1) = "{" AndAlso _
                   Left(Trim(fieldInitializer), 1) = "{" Then
                    If MergeSimpleCMemberDesignatorInitializers( _
                        fieldValues(existingField), fieldInitializer, _
                        nestedInitializer, depth + 1, _
                        allowLiteralOverrides) <> 0 Then
                        fieldValues(existingField) = nestedInitializer
                    ElseIf allowLiteralOverrides <> 0 AndAlso _
                           IsIdentifierFreeInitializer( _
                               fieldValues(existingField)) <> 0 AndAlso _
                           IsIdentifierFreeInitializer(fieldInitializer) <> 0 Then
                        fieldValues(existingField) = fieldInitializer
                    Else
                        Return 0
                    End If
                ElseIf allowLiteralOverrides <> 0 AndAlso _
                       IsIdentifierFreeInitializer( _
                           fieldValues(existingField)) <> 0 AndAlso _
                       IsIdentifierFreeInitializer(fieldInitializer) <> 0 Then
                    fieldValues(existingField) = fieldInitializer
                Else
                    Return 0
                End If
            Else
                If fieldCount >= MAX_TYPE_WORDS Then Return 0
                fieldNames(fieldCount) = fieldName
                fieldValues(fieldCount) = fieldInitializer
                fieldCount += 1
            End If
        Next
    Next

    If fieldCount = 0 Then Return 0
    mergedText = "{ "
    For fieldIndex As Long = 0 To fieldCount - 1
        If fieldIndex > 0 Then mergedText &= ", "
        mergedText &= "." & fieldNames(fieldIndex) & " = " & _
            fieldValues(fieldIndex)
    Next
    mergedText &= " }"
    Return -1
End Function

Private Function SimpleInitializerMayHaveSideEffects( _
    ByVal initializerText As String _
) As Long
    initializerText = Trim(initializerText)
    Dim position As Long = 1
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    While position <= Len(initializerText)
        Dim currentByte As Long = Asc(initializerText, position)
        If quoteByte <> 0 Then
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
        ElseIf Mid(initializerText, position, 2) = "/*" Then
            Dim commentEnd As Long = InStr(position + 2, initializerText, "*/")
            If commentEnd = 0 Then Return 0
            position = commentEnd + 2
            Continue While
        ElseIf Mid(initializerText, position, 2) = "//" Then
            Dim lineEnd As Long = InStr(position + 2, initializerText, Chr(10))
            If lineEnd = 0 Then Return 0
            position = lineEnd + 1
            Continue While
        ElseIf currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quoteByte = currentByte
        ElseIf Mid(initializerText, position, 2) = "++" OrElse _
               Mid(initializerText, position, 2) = "--" Then
            Return -1
        End If
        position += 1
    Wend
    If Left(initializerText, 1) = "{" Then
        If Right(initializerText, 1) <> "}" Then Return -1
        Dim initializerBody As String = Trim(Mid( _
            initializerText, 2, Len(initializerText) - 2))
        If Right(initializerBody, 1) = "," Then _
            initializerBody = RTrim(Left(initializerBody, Len(initializerBody) - 1))
        Dim values() As String
        Dim valueCount As Long
        If initializerBody = "" Then Return 0
        If SplitSimpleCList(initializerBody, values(), valueCount) = 0 Then Return -1
        For valueIndex As Long = 0 To valueCount - 1
            Dim valueText As String = Trim(values(valueIndex))
            If Left(valueText, 1) = "." Then
                Dim fieldName As String
                Dim fieldInitializer As String
                If ParseSimpleCMemberDesignator( _
                    valueText, fieldName, fieldInitializer) = 0 Then Return -1
                valueText = fieldInitializer
            End If
            If SimpleInitializerMayHaveSideEffects(valueText) <> 0 Then Return -1
        Next
        Return 0
    End If
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(initializerText, tokens(), tokenCount)
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case tokens(tokenIndex)
        Case "++", "--", "=", "+=", "-=", "*=", "/=", "%=", _
             "&=", "|=", "^=", "<<=", ">>="
            Return -1
        End Select
    Next
    Return 0
End Function

Private Function TranslateSimpleRecordArrayInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal initializerText As String, _
    ByVal elementType As String, ByVal arrayBound As String, _
    ByVal fieldLabel As String, _
    ByRef translatedValue As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long, _
    ByVal requireConstant As Long = 0 _
) As Long
    translatedValue = ""
    Dim arrayCount As Long
    If EvaluateSimpleArrayBound( _
        arrayBound, arrayCount, MAX_SIMPLE_ARRAY_COUNT) = 0 OrElse _
       arrayCount < 1 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-record-array-bound", _
            "unsupported fixed array member bound for " & fieldLabel)
        Return 0
    End If

    Dim values() As String
    Dim valueCount As Long = 0
    Dim isStringInitializer As Long = 0
    initializerText = Trim(initializerText)
    If initializerText <> "" Then
        If Left(initializerText, 1) = Chr(34) Then
            If elementType <> "Byte" AndAlso elementType <> "UByte" AndAlso _
               elementType <> "c2fb_c_char" AndAlso _
               elementType <> "c2fb_c_uchar" Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-record-array-string", _
                    "string initializer does not match array member " & fieldLabel)
                Return 0
            End If
            Dim stringValues As String
            Dim stringByteCount As Long
            ' Record fields can hold generated tables larger than call arguments.
            If ReadSimpleStaticStringArray( _
                initializerText, stringValues, stringByteCount) = 0 OrElse _
               SplitSimpleCList( _
                   stringValues, values(), valueCount, 0, _
                   MAX_GENERIC_STATIC_INITIALIZER_VALUES) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-record-array-string", _
                    "unsupported string initializer for array member " & fieldLabel)
                Return 0
            End If
            isStringInitializer = -1
        ElseIf Left(initializerText, 1) = "{" AndAlso _
               Right(initializerText, 1) = "}" Then
            Dim initializerBody As String = Trim(Mid( _
                initializerText, 2, Len(initializerText) - 2))
            If Right(initializerBody, 1) = "," Then _
                initializerBody = RTrim(Left(initializerBody, Len(initializerBody) - 1))
            If initializerBody <> "" AndAlso _
               SplitSimpleCList( _
                   initializerBody, values(), valueCount, 0, _
                   MAX_GENERIC_STATIC_INITIALIZER_VALUES) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-record-array-initializer", _
                    "unsupported array initializer for member " & fieldLabel)
                Return 0
            End If
        Else
            RecordSimpleBodyFailure( _
                context, "unsupported-record-array-initializer", _
                "array member requires a brace or string initializer: " & fieldLabel)
            Return 0
        End If
    End If
    If isStringInitializer <> 0 AndAlso valueCount = arrayCount + 1 AndAlso _
       Trim(values(arrayCount)) = "0" Then valueCount -= 1
    If valueCount > arrayCount Then
        RecordSimpleBodyFailure( _
            context, "record-array-initializer-too-large", _
            "too many values in array member initializer " & fieldLabel)
        Return 0
    End If

    Dim nestedRecord As String
    If InStr(elementType, " Ptr") = 0 AndAlso _
       IsCBodyCallbackTypeInContext(translation, elementType) = 0 Then
        nestedRecord = CBodyRecordName(translation, catalog, elementType)
    End If
    If SimpleArithmeticKind(catalog, elementType) = 0 AndAlso _
       InStr(elementType, " Ptr") = 0 AndAlso _
       IsCBodyCallbackTypeInContext(translation, elementType) = 0 AndAlso _
       nestedRecord = "" Then
        RecordSimpleBodyFailure( _
            context, "unsupported-record-array-element", _
            "unsupported array member element type " & fieldLabel & " As " & elementType)
        Return 0
    End If

    Dim resultValues As String
    For valueIndex As Long = 0 To arrayCount - 1
        Dim elementValue As String
        If valueIndex >= valueCount Then
            If nestedRecord <> "" Then
                If TranslateSimpleRecordInitializer( _
                    translation, catalog, "{}", elementType, elementValue, _
                    context, callableNames(), callableCount, parameterNames(), _
                    parameterAliases(), parameterTypes(), parameterCount, _
                    requireConstant) = 0 Then _
                    Return 0
            ElseIf InStr(elementType, " Ptr") <> 0 OrElse _
                   IsCBodyCallbackTypeInContext(translation, elementType) <> 0 Then
                elementValue = "CPtr(" & elementType & ", 0)"
            Else
                elementValue = "Cast(" & elementType & ", 0)"
            End If
        ElseIf nestedRecord <> "" Then
            If TranslateSimpleRecordInitializer( _
                translation, catalog, values(valueIndex), elementType, _
                elementValue, context, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                parameterCount, requireConstant) = 0 Then Return 0
        Else
            Dim hasBoolean As Long
            Dim hasFunctionCall As Long
            If TranslateSimpleExpression( _
                translation, catalog, values(valueIndex), elementValue, _
                hasBoolean, hasFunctionCall, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                parameterCount, elementType, -1, requireConstant) = 0 OrElse _
               hasFunctionCall <> 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-record-array-element", _
                    "unsupported array initializer element for " & fieldLabel & ": " & _
                    Left(values(valueIndex), 120))
                Return 0
            End If
            If requireConstant <> 0 Then _
                NormalizeGenericStaticInitializerValue(elementValue)
        End If
        If resultValues <> "" Then resultValues &= ", "
        resultValues &= elementValue
    Next
    translatedValue = "{" & resultValues & "}"
    Return -1
End Function

Private Function TranslateSimpleNestedRecordValue( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal initializerText As String, ByVal freeBasicType As String, _
    ByRef translatedValue As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long, _
    ByVal requireConstant As Long _
) As Long
    initializerText = Trim(initializerText)
    If Left(initializerText, 1) = "{" Then _
        Return TranslateSimpleRecordInitializer( _
            translation, catalog, initializerText, freeBasicType, _
            translatedValue, context, callableNames(), callableCount, _
            parameterNames(), parameterAliases(), parameterTypes(), _
            parameterCount, requireConstant)

    ' A nested C record may be copied from an existing object. Restrict this
    ' case to an identifier so a Basic constructor cannot reorder side effects.
    If IsIdentifierToken(initializerText) = 0 Then Return 0
    Dim hasBoolean As Long
    Dim hasFunctionCall As Long
    If TranslateSimpleExpression( _
        translation, catalog, initializerText, translatedValue, _
        hasBoolean, hasFunctionCall, callableNames(), callableCount, _
        parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount, freeBasicType, -1, requireConstant) = 0 OrElse _
       hasFunctionCall <> 0 Then
        Return 0
    End If
    Return -1
End Function

Private Function AppendSimpleBodyUnionInitializerHelper( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef context As SimpleBodyContext, _
    ByVal unionType As String, ByVal fieldType As String, _
    ByVal freeBasicFieldName As String, ByRef helperName As String _
) As Long
    helperName = ""
    If unionType = "" OrElse fieldType = "" OrElse _
       freeBasicFieldName = "" OrElse IsIdentifierToken(freeBasicFieldName) = 0 OrElse _
       Left(unionType, 6) = "Const " Then Return 0

    Dim serial As Long = translation.body.generatedAggregateInitializerSerial
    Do
        helperName = "c2fb_union_initializer_" & Trim(Str(serial))
        serial += 1
    Loop While CBodyProcedureIndex(translation, helperName) >= 0 OrElse _
               CBodyExternalObjectIndex(translation, helperName) >= 0
    translation.body.generatedAggregateInitializerSerial = serial

    context.generatedBodyHelpers &= _
        "' C union initialization selects this member explicitly" & Chr(10) & _
        "Private Function " & helperName & _
        " (ByVal c2fb_union_value As " & fieldType & ") As " & unionType & Chr(10) & _
        "    Dim c2fb_union_result As " & unionType & Chr(10) & _
        "    c2fb_union_result." & freeBasicFieldName & _
        " = c2fb_union_value" & Chr(10) & _
        "    Return c2fb_union_result" & Chr(10) & _
        "End Function" & Chr(10) & Chr(10)
    Return -1
End Function

Private Function AppendSimpleBodyRecordInitializerHelper( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef context As SimpleBodyContext, _
    ByVal recordType As String, _
    ByVal parameters As String, ByVal assignments As String, _
    ByRef helperName As String _
) As Long
    helperName = ""
    If recordType = "" OrElse parameters = "" OrElse assignments = "" OrElse _
       Left(recordType, 6) = "Const " Then Return 0

    Dim serial As Long = translation.body.generatedAggregateInitializerSerial
    Do
        helperName = "c2fb_record_initializer_" & Trim(Str(serial))
        serial += 1
    Loop While CBodyProcedureIndex(translation, helperName) >= 0 OrElse _
               CBodyExternalObjectIndex(translation, helperName) >= 0
    translation.body.generatedAggregateInitializerSerial = serial

    context.generatedBodyHelpers &= _
        "' C aggregates with union or long-double fields need field-by-field assignment" & Chr(10) & _
        "Private Function " & helperName & " (" & parameters & _
        ") As " & recordType & Chr(10) & _
        "    Dim c2fb_record_result As " & recordType & Chr(10) & _
        assignments & _
        "    Return c2fb_record_result" & Chr(10) & _
        "End Function" & Chr(10) & Chr(10)
    Return -1
End Function

Private Function TranslateSimpleRecordInitializerWithPrelude( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal initializerText As String, _
    ByVal freeBasicType As String, _
    ByRef translatedValue As String, _
    ByRef initializerPrelude As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long, _
    ByVal requireConstant As Long = 0 _
) As Long
    translatedValue = ""
    initializerPrelude = ""
    initializerText = Trim(initializerText)
    If Left(initializerText, 1) <> "{" OrElse Right(initializerText, 1) <> "}" Then Return 0

    Dim sourceRecord As String = CBodyRecordName( _
        translation, catalog, freeBasicType)
    If sourceRecord = "" OrElse CBodyRecordSizeIsKnown( _
        translation, catalog, sourceRecord) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-static-record-type", _
            "unsupported static record type " & freeBasicType)
        Return 0
    End If
    Dim sourceRecordKind As C2fbRecordKind = _
        CBodySourceRecordKindInContext(translation, sourceRecord)
    Dim initializerBody As String = Trim(Mid(initializerText, 2, Len(initializerText) - 2))
    If Right(initializerBody, 1) = "," Then _
        initializerBody = RTrim(Left(initializerBody, Len(initializerBody) - 1))

    Dim values() As String
    Dim valueCount As Long = 0
    If initializerBody <> "" Then
        If SplitSimpleCList(initializerBody, values(), valueCount) = 0 Then Return 0
    End If

    Dim isDesignatedInitializer As Long = 0
    For valueIndex As Long = 0 To valueCount - 1
        If Left(Trim(values(valueIndex)), 1) = "." Then _
            isDesignatedInitializer = -1
    Next
    Dim designatedValues() As String
    Dim designatedFields() As Long
    Dim sourceFieldIndexes() As Long
    Dim sourceFieldCount As Long = 0
    If isDesignatedInitializer <> 0 Then
        If translation.body.recordFieldCount <= 0 Then Return 0
        ReDim designatedValues(0 To translation.body.recordFieldCount - 1)
        ReDim designatedFields(0 To translation.body.recordFieldCount - 1)
        ReDim sourceFieldIndexes(0 To translation.body.recordFieldCount - 1)
        For cField As Long = 0 To translation.body.recordFieldCount - 1
            If translation.body.recordFields(cField).ownerName <> sourceRecord Then Continue For
            sourceFieldIndexes(sourceFieldCount) = cField
            sourceFieldCount += 1
        Next
        If sourceFieldCount = 0 Then Return 0
        Dim nextFieldOrdinal As Long = 0
        Dim previousFieldOrdinal As Long = -1
        Dim hasInitializerReordering As Long = 0
        For valueIndex As Long = 0 To valueCount - 1
            Dim fieldOrdinal As Long
            Dim fieldInitializer As String
            Dim fieldName As String
            If Left(Trim(values(valueIndex)), 1) = "." Then
                If ParseSimpleCMemberDesignator( _
                    values(valueIndex), fieldName, fieldInitializer) = 0 Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-record-designator", _
                        "unsupported record member designator: " & _
                        Left(values(valueIndex), 120))
                    Return 0
                End If
                fieldOrdinal = -1
                For sourceFieldOrdinal As Long = 0 To sourceFieldCount - 1
                    Dim sourceFieldIndex As Long = _
                        sourceFieldIndexes(sourceFieldOrdinal)
                    If translation.body.recordFields(sourceFieldIndex).name = fieldName Then
                        fieldOrdinal = sourceFieldOrdinal
                        Exit For
                    End If
                Next
                If fieldOrdinal < 0 Then
                    RecordSimpleBodyFailure( _
                        context, "unknown-record-designator", _
                        "unknown record member designator " & sourceRecord & "." & _
                        fieldName)
                    Return 0
                End If
                nextFieldOrdinal = fieldOrdinal + 1
            Else
                If nextFieldOrdinal >= sourceFieldCount Then
                    RecordSimpleBodyFailure( _
                        context, "record-initializer-field-count-mismatch", _
                        "too many values in record initializer " & sourceRecord)
                    Return 0
                End If
                fieldOrdinal = nextFieldOrdinal
                fieldInitializer = Trim(values(valueIndex))
                nextFieldOrdinal += 1
            End If
            If previousFieldOrdinal >= 0 AndAlso _
               fieldOrdinal < previousFieldOrdinal Then _
                hasInitializerReordering = -1
            previousFieldOrdinal = fieldOrdinal
            Dim fieldIndex As Long = sourceFieldIndexes(fieldOrdinal)
            If designatedFields(fieldIndex) <> 0 Then
                Dim mergedInitializer As String
                If MergeSimpleCMemberDesignatorInitializers( _
                    designatedValues(fieldIndex), fieldInitializer, _
                    mergedInitializer) = 0 Then
                    RecordSimpleBodyFailure( _
                        context, "duplicate-record-initializer-field", _
                        "record field initialized more than once: " & sourceRecord & "." & _
                        translation.body.recordFields(fieldIndex).name)
                    Return 0
                End If
                designatedValues(fieldIndex) = mergedInitializer
            Else
                designatedValues(fieldIndex) = fieldInitializer
                designatedFields(fieldIndex) = -1
            End If
        Next
        If hasInitializerReordering <> 0 Then
            For cField As Long = 0 To translation.body.recordFieldCount - 1
                If designatedFields(cField) = 0 Then Continue For
                If SimpleInitializerMayHaveSideEffects( _
                    designatedValues(cField)) <> 0 Then
                    RecordSimpleBodyFailure( _
                        context, "designated-initializer-order-not-preserved", _
                        "cannot preserve side effects in reordered record initializer " & _
                        sourceRecord)
                    Return 0
                End If
            Next
        End If
    End If

    Dim fieldCount As Long = 0
    Dim resultFields As String = ""
    Dim recordHelperParameters As String = ""
    Dim recordHelperArguments As String = ""
    Dim recordHelperAssignments As String = ""
    Dim hasUnionStorageField As Long = 0
    Dim hasLongDoubleField As Long = 0
    Dim canUseRecordHelper As Long = -1
    Dim previousAnonymousUnionGroup As Long = 0
    If sourceRecord = "FuncDef.u" Then
        If LookupFbBodyField( _
            translation, catalog, freeBasicType, "pHash") < 0 OrElse _
           valueCount > 1 OrElse (valueCount = 1 AndAlso Trim(values(0)) <> "0") Then Return 0
        ' The port's union members are opaque pointers, and this source table
        ' explicitly initializes the union to null before insertion.
        Dim unionValue As String = "Cast(Any Ptr, 0)"
        translatedValue = "Type<" & freeBasicType & ">( " & unionValue & " )"
        Return -1
    End If
    If sourceRecordKind = C2FB_RECORD_UNION Then
        If valueCount > 1 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-static-union-initializer", _
                "C union initializer must select its first member: " & sourceRecord)
            Return 0
        End If
        Dim firstField As Long = -1
        Dim firstUnionMember As Long = -1
        Dim selectedFieldCount As Long = 0
        For cField As Long = 0 To translation.body.recordFieldCount - 1
            If translation.body.recordFields(cField).ownerName = sourceRecord Then
                If firstField < 0 Then
                    firstField = cField
                    firstUnionMember = cField
                End If
                If isDesignatedInitializer <> 0 Then
                    If designatedFields(cField) <> 0 Then
                        firstField = cField
                        selectedFieldCount += 1
                    End If
                ElseIf firstField = cField Then
                    Exit For
                End If
            End If
        Next
        If isDesignatedInitializer <> 0 AndAlso selectedFieldCount <> 1 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-union-designator", _
                "union initializer must select exactly one member: " & sourceRecord)
            Return 0
        End If
        If firstField < 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-static-union-initializer", _
                "union has no initializable first member: " & sourceRecord)
            Return 0
        End If
        Dim firstMemberIsArray As Long = _
            translation.body.recordFields(firstField).isArray
        Dim firstMemberArrayCount As Long = 0
        If firstMemberIsArray <> 0 Then
            With translation.body.recordFields(firstField)
                If .isFlexibleArray <> 0 OrElse .pointerCount <> 0 OrElse _
                   .bitWidth >= 0 OrElse _
                   EvaluateSimpleArrayBound( _
                       .arrayBound, firstMemberArrayCount, _
                       MAX_C2FB_UNION_ARRAY_INITIALIZER_ELEMENTS) = 0 OrElse _
                   firstMemberArrayCount < 1 Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-static-union-array-initializer", _
                        "unsupported fixed-array first C union member: " & _
                        sourceRecord)
                    Return 0
                End If
            End With
        End If
        Dim fieldName As String = translation.body.recordFields(firstField).name
        Dim fieldType As String = CBodyFieldType( _
            translation, catalog, firstField, _
            CInt(firstMemberIsArray = 0) * -1)
        Dim fbFieldIndex As Long = LookupFbBodyField( _
            translation, catalog, freeBasicType, fieldName, firstField)
        If fieldType = "" OrElse fbFieldIndex < 0 Then Return 0
        If firstMemberIsArray <> 0 Then
            Dim arrayUnionInitializer As String
            If valueCount > 0 Then
                If isDesignatedInitializer <> 0 Then
                    arrayUnionInitializer = designatedValues(firstField)
                Else
                    arrayUnionInitializer = values(0)
                End If
            End If
            Dim arrayInitializer As String = "{}"
            If valueCount > 0 Then
                arrayInitializer = Trim(arrayUnionInitializer)
                If Left(arrayInitializer, 1) <> "{" AndAlso _
                   Left(arrayInitializer, 1) <> Chr(34) Then _
                    arrayInitializer = "{" & arrayInitializer & "}"
            End If
            Dim translatedArrayInitializer As String
            If TranslateSimpleRecordArrayInitializer( _
                translation, catalog, arrayInitializer, fieldType, _
                translation.body.recordFields(firstField).arrayBound, _
                sourceRecord & "." & fieldName, translatedArrayInitializer, _
                context, callableNames(), callableCount, parameterNames(), _
                parameterAliases(), parameterTypes(), parameterCount, _
                requireConstant) = 0 Then Return 0
            Dim unionArrayValues As String = Trim(Mid( _
                translatedArrayInitializer, 2, _
                Len(translatedArrayInitializer) - 2))
            translatedValue = "Type<" & freeBasicType & ">( " & _
                unionArrayValues & " )"
            Return -1
        End If
        Dim nestedRecord As String
        If InStr(fieldType, " Ptr") = 0 AndAlso _
           IsCBodyCallbackTypeInContext(translation, fieldType) = 0 Then
            nestedRecord = CBodyRecordName(translation, catalog, fieldType)
        End If
        If SimpleArithmeticKind(catalog, fieldType) = 0 AndAlso _
           InStr(fieldType, " Ptr") = 0 AndAlso _
           IsCBodyCallbackTypeInContext(translation, fieldType) = 0 AndAlso _
           nestedRecord = "" Then Return 0

        Dim unionFieldValue As String
        Dim unionInitializer As String
        If valueCount > 0 Then
            If isDesignatedInitializer <> 0 Then
                unionInitializer = designatedValues(firstField)
            Else
                unionInitializer = values(0)
            End If
        End If
        If valueCount = 0 Then
            If nestedRecord <> "" Then
                If TranslateSimpleRecordInitializer( _
                    translation, catalog, "{}", fieldType, unionFieldValue, _
                    context, callableNames(), callableCount, parameterNames(), _
                    parameterAliases(), parameterTypes(), parameterCount, _
                    requireConstant) = 0 Then _
                    Return 0
            ElseIf InStr(fieldType, " Ptr") <> 0 OrElse _
                   IsCBodyCallbackTypeInContext(translation, fieldType) <> 0 Then
                unionFieldValue = "CPtr(" & fieldType & ", 0)"
            Else
                unionFieldValue = "Cast(" & fieldType & ", 0)"
            End If
        ElseIf nestedRecord <> "" Then
            If TranslateSimpleNestedRecordValue( _
                translation, catalog, unionInitializer, fieldType, unionFieldValue, _
                context, callableNames(), callableCount, parameterNames(), _
                parameterAliases(), parameterTypes(), parameterCount, _
                requireConstant) = 0 Then _
                Return 0
        Else
            Dim hasBoolean As Long
            Dim hasFunctionCall As Long
            If TranslateSimpleExpression( _
                translation, catalog, unionInitializer, unionFieldValue, hasBoolean, _
                hasFunctionCall, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                parameterCount, fieldType, -1, requireConstant) = 0 OrElse _
               hasFunctionCall <> 0 Then _
                Return 0
        End If
        If ConvertSimpleRecordInitializerFieldStorage( _
            translation, catalog, sourceRecord, fieldName, fieldType, _
            fbFieldIndex, unionFieldValue, context) = 0 Then Return 0
        If isDesignatedInitializer <> 0 Then
            If requireConstant <> 0 Then
                If firstField <> firstUnionMember Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-static-designated-union-initializer", _
                        "static C union initializer selects a non-first member: " & _
                        sourceRecord)
                    Return 0
                End If
                translatedValue = "Type<" & freeBasicType & ">( " & _
                    unionFieldValue & " )"
                Return -1
            End If
            Dim helperName As String
            Dim unionStorageType As String = NormalizeFbBodyType( _
                catalog, catalog.bodyFields(fbFieldIndex).typeName)
            If unionStorageType = "" Then Return 0
            If AppendSimpleBodyUnionInitializerHelper( _
                translation, catalog, context, freeBasicType, unionStorageType, _
                catalog.bodyFields(fbFieldIndex).name, helperName) = 0 Then _
                Return 0
            translatedValue = helperName & "(" & unionFieldValue & ")"
        Else
            translatedValue = "Type<" & freeBasicType & ">( " & _
                unionFieldValue & " )"
        End If
        Return -1
    End If
    For cField As Long = 0 To translation.body.recordFieldCount - 1
        If translation.body.recordFields(cField).ownerName <> sourceRecord Then Continue For
        Dim anonymousUnionGroup As Long = _
            translation.body.recordFields(cField).anonymousUnionGroup
        If anonymousUnionGroup <> 0 AndAlso _
           anonymousUnionGroup = previousAnonymousUnionGroup Then Continue For
        previousAnonymousUnionGroup = anonymousUnionGroup
        Dim isArrayField As Long = translation.body.recordFields(cField).isArray
        Dim fieldType As String
        If isArrayField <> 0 Then
            fieldType = CBodyFieldType(translation, catalog, cField, 0)
        Else
            fieldType = CBodyFieldType(translation, catalog, cField)
        End If
        If UCase(Trim(fieldType)) = "CLONGDOUBLE" Then
            hasLongDoubleField = -1
        End If
        Dim nestedRecord As String
        Dim fbFieldIndex As Long = LookupFbBodyField( _
            translation, catalog, freeBasicType, _
            translation.body.recordFields(cField).name, cField)
        Dim isFuncDefUnionStorage As Long = 0
        If sourceRecord = "FuncDef" AndAlso _
           translation.body.recordFields(cField).name = "u" AndAlso fbFieldIndex >= 0 AndAlso _
           NormalizeFbBodyType( _
               catalog, _
               catalog.bodyFields(fbFieldIndex).typeName) = "Any Ptr" Then
            ' The C union is represented by the same pointer-sized slot in
            ' this port so static table initialization stays a scalar value.
            fieldType = "Any Ptr"
            isFuncDefUnionStorage = -1
        ElseIf InStr(fieldType, " Ptr") = 0 AndAlso _
               IsCBodyCallbackTypeInContext(translation, fieldType) = 0 Then
            nestedRecord = CBodyRecordName( _
                translation, catalog, fieldType)
        End If
        If SimpleArithmeticKind(catalog, fieldType) = 0 AndAlso _
           InStr(fieldType, " Ptr") = 0 AndAlso _
           IsCBodyCallbackTypeInContext(translation, fieldType) = 0 AndAlso nestedRecord = "" Then
            RecordSimpleBodyFailure( _
                context, "unsupported-static-record-field-type", _
                "unsupported static record field type " & sourceRecord & "." & _
                translation.body.recordFields(cField).name & " As " & fieldType)
            Return 0
        End If
        If LookupFbBodyField( _
            translation, catalog, freeBasicType, _
            translation.body.recordFields(cField).name, cField) < 0 Then
            RecordSimpleBodyFailure( _
                context, "missing-mapped-static-record-field", _
                "missing mapped static record field " & freeBasicType & "." & _
                translation.body.recordFields(cField).name)
            Return 0
        End If
        If isArrayField <> 0 AndAlso _
           catalog.bodyFields(fbFieldIndex).isArray = 0 Then
            RecordSimpleBodyFailure( _
                context, "record-array-field-layout-mismatch", _
                "C array member is not an array in the FreeBASIC layout: " & _
                sourceRecord & "." & translation.body.recordFields(cField).name)
            Return 0
        End If
        Dim fieldValue As String
        Dim fieldInitializer As String
        Dim hasFieldInitializer As Long = 0
        If isDesignatedInitializer <> 0 Then
            If designatedFields(cField) <> 0 Then
                fieldInitializer = designatedValues(cField)
                hasFieldInitializer = -1
            End If
        ElseIf fieldCount < valueCount Then
            fieldInitializer = values(fieldCount)
            hasFieldInitializer = -1
        End If
        If anonymousUnionGroup <> 0 AndAlso isDesignatedInitializer <> 0 Then
            Dim selectedUnionMember As Long = -1
            For sourceFieldOrdinal As Long = 0 To sourceFieldCount - 1
                Dim sourceFieldIndex As Long = _
                    sourceFieldIndexes(sourceFieldOrdinal)
                If translation.body.recordFields(sourceFieldIndex).anonymousUnionGroup <> _
                   anonymousUnionGroup OrElse designatedFields(sourceFieldIndex) = 0 Then _
                    Continue For
                If selectedUnionMember >= 0 Then
                    RecordSimpleBodyFailure( _
                        context, "multiple-anonymous-union-designators", _
                        "multiple anonymous union members are initialized in " & _
                        sourceRecord)
                    Return 0
                End If
                selectedUnionMember = sourceFieldIndex
            Next
            If selectedUnionMember >= 0 AndAlso selectedUnionMember <> cField Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-anonymous-union-designator", _
                    "cannot preserve a non-first anonymous union designator in " & _
                    sourceRecord)
                Return 0
            End If
            If selectedUnionMember = cField Then
                fieldInitializer = designatedValues(cField)
                hasFieldInitializer = -1
            Else
                hasFieldInitializer = 0
            End If
        End If
        If anonymousUnionGroup <> 0 AndAlso hasFieldInitializer <> 0 AndAlso _
           Left(Trim(fieldInitializer), 1) = "{" Then
            Dim initializerEnd As Long = 1
            If ScanSimpleExpressionGroup( _
                fieldInitializer, initializerEnd, Asc("{"), Asc("}")) = 0 OrElse _
               Trim(Mid(fieldInitializer, initializerEnd)) <> "" Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-anonymous-union-initializer", _
                    "malformed anonymous union initializer in " & sourceRecord)
                Return 0
            End If
            Dim unionInitializerBody As String = Trim(Mid( _
                fieldInitializer, 2, initializerEnd - 3))
            If unionInitializerBody = "" Then
                fieldInitializer = "0"
            Else
                Dim unionValues() As String
                Dim unionValueCount As Long
                If SplitSimpleCList( _
                    unionInitializerBody, unionValues(), unionValueCount) = 0 OrElse _
                   unionValueCount <> 1 Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-anonymous-union-initializer", _
                        "anonymous union initializer must select one member in " & _
                        sourceRecord)
                    Return 0
                End If
                fieldInitializer = Trim(unionValues(0))
            End If
        End If
        If isArrayField <> 0 Then
            canUseRecordHelper = 0
            Dim arrayInitializer As String
            If hasFieldInitializer <> 0 Then arrayInitializer = fieldInitializer
            If TranslateSimpleRecordArrayInitializer( _
                translation, catalog, arrayInitializer, fieldType, _
                translation.body.recordFields(cField).arrayBound, _
                sourceRecord & "." & translation.body.recordFields(cField).name, _
                fieldValue, context, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                parameterCount, requireConstant) = 0 Then Return 0
        ElseIf hasFieldInitializer <> 0 Then
            If isFuncDefUnionStorage <> 0 Then
                Dim funcDefUnionInitializer As String = Trim(fieldInitializer)
                If funcDefUnionInitializer <> "{0}" AndAlso _
                   funcDefUnionInitializer <> "{}" Then Return 0
                fieldValue = "Cast(Any Ptr, 0)"
            ElseIf nestedRecord <> "" Then
                If TranslateSimpleNestedRecordValue(translation, catalog, _
                    fieldInitializer, fieldType, fieldValue, context, _
                    callableNames(), callableCount, parameterNames(), parameterAliases(), _
                    parameterTypes(), parameterCount, requireConstant) = 0 Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-nested-record-value-initializer", _
                        "unsupported nested record initializer " & sourceRecord & "." & _
                        translation.body.recordFields(cField).name & " from " & fieldInitializer)
                    Return 0
                End If
			ElseIf IsCBodyCallbackTypeInContext(translation, fieldType) <> 0 Then
				If TranslateCBodyCallbackInitializer( _
				    translation, catalog, fieldInitializer, fieldType, fieldValue) = 0 Then
					RecordSimpleBodyFailure( _
					    context, "unsupported-static-record-callback-initializer", _
					    "unsupported static callback initializer " & sourceRecord & "." & _
					    translation.body.recordFields(cField).name & " from " & fieldInitializer)
					Return 0
				End If
            Else
                If requireConstant = 0 Then
                    Dim fieldPrelude As String
                    If TranslateSequencedExpression( _
                        translation, catalog, fieldInitializer, fieldValue, _
                        fieldPrelude, context, callableNames(), callableCount, _
                        parameterNames(), parameterAliases(), parameterTypes(), _
                        parameterCount, fieldType) = 0 Then
                        RecordSimpleBodyFailure( _
                            context, "unsupported-record-initializer-expression", _
                            "unsupported automatic record initializer " & sourceRecord & "." & _
                            translation.body.recordFields(cField).name & " from " & fieldInitializer)
                        Return 0
                    End If
                    If fieldPrelude <> "" Then
                        If initializerPrelude <> "" AndAlso _
                           Right(initializerPrelude, 1) <> Chr(10) Then _
                            initializerPrelude &= Chr(10)
                        initializerPrelude &= RTrim(fieldPrelude, Any Chr(10))
                        If Right(initializerPrelude, 1) <> Chr(10) Then _
                            initializerPrelude &= Chr(10)
                    End If
                Else
                    Dim hasBoolean As Long
                    Dim hasFunctionCall As Long
                    If TranslateSimpleExpression(translation, catalog, _
                        fieldInitializer, fieldValue, hasBoolean, hasFunctionCall, _
                        callableNames(), callableCount, parameterNames(), _
                        parameterAliases(), parameterTypes(), parameterCount, _
                        fieldType, -1, requireConstant) = 0 OrElse _
                       hasFunctionCall <> 0 Then
                        RecordSimpleBodyFailure( _
                            context, "unsupported-static-record-initializer", _
                            "unsupported static record initializer " & sourceRecord & "." & _
                            translation.body.recordFields(cField).name & " from " & fieldInitializer)
                        Return 0
                    End If
                    If requireConstant <> 0 Then _
                        NormalizeGenericStaticInitializerValue(fieldValue)
                End If
            End If
        Else
            If nestedRecord <> "" Then
                If TranslateSimpleRecordInitializer(translation, catalog, "{}", fieldType, fieldValue, context, _
                    callableNames(), callableCount, parameterNames(), parameterAliases(), _
                    parameterTypes(), parameterCount, requireConstant) = 0 Then Return 0
            ElseIf IsCBodyCallbackTypeInContext(translation, fieldType) <> 0 Then
                fieldValue = "CPtr(" & fieldType & ", 0)"
            Else
                fieldValue = "Cast(" & fieldType & ", 0)"
            End If
        End If
        If freeBasicType = "SqliteFuncDef" AndAlso _
           translation.body.recordFields(cField).name = "funcFlags" Then
            ' SqliteFuncDef keeps C's alignment padding as an explicit field.
            ' C aggregate initialization omits this unnamed padding member.
            If resultFields <> "" Then resultFields &= ", "
            resultFields &= "Cast(u16, 0)"
            canUseRecordHelper = 0
        End If
        ' Array layout already comes from the record binding; scalar casts
        ' would turn a nested array initializer into an invalid scalar value.
        If isArrayField = 0 AndAlso ConvertSimpleRecordInitializerFieldStorage( _
            translation, catalog, sourceRecord, _
            translation.body.recordFields(cField).name, fieldType, _
            fbFieldIndex, fieldValue, context) = 0 Then Return 0
        If resultFields <> "" Then resultFields &= ", "
        resultFields &= fieldValue
        Dim freeBasicFieldName As String = _
            catalog.bodyFields(fbFieldIndex).name
        If freeBasicFieldName = "" OrElse _
           IsIdentifierToken(freeBasicFieldName) = 0 Then
            canUseRecordHelper = 0
        Else
            Dim helperArgumentName As String = _
                "c2fb_record_value_" & Trim(Str(fieldCount))
            If recordHelperParameters <> "" Then
                recordHelperParameters &= ", "
                recordHelperArguments &= ", "
            End If
            recordHelperParameters &= "ByVal " & helperArgumentName & _
                " As " & fieldType
            recordHelperArguments &= fieldValue
            recordHelperAssignments &= _
                "    c2fb_record_result." & freeBasicFieldName & _
                " = " & helperArgumentName & Chr(10)
            If catalog.bodyFields(fbFieldIndex).isUnionMember <> 0 Then _
                hasUnionStorageField = -1
        End If
        fieldCount += 1
    Next
    Dim initializerFieldCount As Long = valueCount
    If isDesignatedInitializer <> 0 Then
        initializerFieldCount = 0
        Dim countedUnionGroup As Long = 0
        For cField As Long = 0 To translation.body.recordFieldCount - 1
            If designatedFields(cField) = 0 Then Continue For
            Dim anonymousUnionGroup As Long = _
                translation.body.recordFields(cField).anonymousUnionGroup
            If anonymousUnionGroup <> 0 AndAlso _
               anonymousUnionGroup = countedUnionGroup Then Continue For
            countedUnionGroup = anonymousUnionGroup
            initializerFieldCount += 1
        Next
    End If
    If fieldCount = 0 OrElse initializerFieldCount > fieldCount Then
        RecordSimpleBodyFailure( _
            context, "static-record-field-count-mismatch", _
            "static record field count mismatch " & sourceRecord & _
            ": source fields=" & Trim(Str(fieldCount)) & _
            ", initializer values=" & Trim(Str(initializerFieldCount)))
        Return 0
    End If
    If (hasUnionStorageField <> 0 OrElse hasLongDoubleField <> 0) AndAlso _
       canUseRecordHelper <> 0 AndAlso _
       requireConstant = 0 Then
        Dim helperName As String
        If AppendSimpleBodyRecordInitializerHelper( _
            translation, catalog, context, freeBasicType, _
            recordHelperParameters, recordHelperAssignments, helperName) = 0 Then _
            Return 0
        translatedValue = helperName & "(" & recordHelperArguments & ")"
    Else
        translatedValue = "Type<" & freeBasicType & ">( " & resultFields & " )"
    End If
    Return -1
End Function

Private Function TranslateSimpleRecordInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal initializerText As String, _
    ByVal freeBasicType As String, _
    ByRef translatedValue As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long, _
    ByVal requireConstant As Long = 0 _
) As Long
    Dim initializerPrelude As String
    If TranslateSimpleRecordInitializerWithPrelude( _
        translation, catalog, initializerText, freeBasicType, translatedValue, _
        initializerPrelude, context, callableNames(), callableCount, _
        parameterNames(), parameterAliases(), parameterTypes(), parameterCount, _
        requireConstant) = 0 Then Return 0
    If initializerPrelude <> "" Then
        RecordSimpleBodyFailure( _
            context, "record-initializer-prelude-not-preserved", _
            "record initializer requires statement sequencing: " & _
            Left(initializerText, 160))
        Return 0
    End If
    Return -1
End Function

Private Function NormalizeCInlineRecordArrayDeclaration( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef context As SimpleBodyContext, _
    ByVal declarationText As String _
) As String
    ' Reuse mapped C tags, or synthesize a private FreeBASIC type for a simple
    ' anonymous local record before ordinary declaration lowering runs.
    Dim structureStart As Long = InStr(declarationText, "struct ")
    Dim unionStart As Long = InStr(declarationText, "union ")
    Dim recordStart As Long = structureStart
    Dim recordKeyword As String = "struct "
    Dim recordKind As C2fbRecordKind = C2FB_RECORD_STRUCT
    If unionStart > 0 AndAlso (recordStart = 0 OrElse unionStart < recordStart) Then
        recordStart = unionStart
        recordKeyword = "union "
        recordKind = C2FB_RECORD_UNION
    End If
    If recordStart = 0 Then
        Dim typePosition As Long = 1
        While typePosition <= Len(declarationText)
            SkipCSpaces(declarationText, typePosition)
            If typePosition > Len(declarationText) Then Exit While
            If IsIdentifierStart(Asc(declarationText, typePosition)) = 0 Then
                Select Case Asc(declarationText, typePosition)
                Case Asc("*"), Asc("["), Asc("("), Asc(",")
                    Exit While
                Case Else
                    typePosition += 1
                    Continue While
                End Select
            End If

            Dim tokenStart As Long = typePosition
            While typePosition <= Len(declarationText) AndAlso _
                  IsIdentifierPart(Asc(declarationText, typePosition)) <> 0
                typePosition += 1
            Wend
            Dim typeName As String = Mid( _
                declarationText, tokenStart, typePosition - tokenStart)
            Dim aliasSourceType As String = _
                SimpleBodyLocalCType(context, typeName)
            Dim aliasType As String = SimpleBodyLocalType(context, typeName)
            If aliasSourceType <> "" OrElse aliasType <> "" Then
                Dim declarationTail As String = Mid(declarationText, typePosition)
                If aliasSourceType <> "" Then _
                    Return Left(declarationText, tokenStart - 1) & _
                           aliasSourceType & declarationTail
                Return Left(declarationText, tokenStart - 1) & _
                       aliasType & declarationTail
            End If

            Select Case typeName
            Case "const", "volatile", "restrict", "__restrict", _
                 "__restrict__", "static", "extern", "register", "auto", _
                 "inline", "__inline", "__inline__", "_Thread_local", _
                 "__thread"
                Continue While
            Case Else
                Exit While
            End Select
        Wend
        Return declarationText
    End If
    Dim tagStart As Long = recordStart + Len(recordKeyword)
    Dim tagEnd As Long = tagStart
    While tagEnd <= Len(declarationText) AndAlso _
          IsIdentifierPart(Asc(declarationText, tagEnd)) <> 0
        tagEnd += 1
    Wend
    If tagEnd = tagStart Then
        Dim anonymousBrace As Long = tagEnd
        While anonymousBrace <= Len(declarationText) AndAlso _
              IsSpaceByte(Asc(declarationText, anonymousBrace)) <> 0
            anonymousBrace += 1
        Wend
        If anonymousBrace > Len(declarationText) OrElse _
           Asc(declarationText, anonymousBrace) <> Asc("{") Then _
            Return declarationText
        Dim recordEnd As Long = anonymousBrace
        If ScanSimpleExpressionGroup( _
            declarationText, recordEnd, Asc("{"), Asc("}")) = 0 Then _
            Return declarationText
        Dim recordBody As String = Mid( _
            declarationText, anonymousBrace + 1, _
            recordEnd - anonymousBrace - 2)
        Dim objectDeclaration As String = Trim(Mid(declarationText, recordEnd))
        If objectDeclaration = "" Then Return declarationText
        Dim objectParts() As String
        Dim objectPartCount As Long
        If SplitSimpleCList( _
            objectDeclaration, objectParts(), objectPartCount) = 0 OrElse _
           objectPartCount = 0 Then Return declarationText
        For objectIndex As Long = 0 To objectPartCount - 1
            If Trim(objectParts(objectIndex)) = "" Then _
                Return declarationText
        Next
        Dim generatedRecordName As String
        If RegisterCBodyAnonymousRecord( _
            translation, catalog, recordBody, generatedRecordName, _
            recordKind) = 0 Then _
            Return declarationText
        Dim prefix As String = Trim(Left(declarationText, recordStart - 1))
        If prefix <> "" Then prefix &= " "
        Return prefix & generatedRecordName & " " & objectDeclaration
    End If

    Dim localTagEnd As Long = tagEnd
    While localTagEnd <= Len(declarationText) AndAlso _
          IsSpaceByte(Asc(declarationText, localTagEnd)) <> 0
        localTagEnd += 1
    Wend
    If localTagEnd <= Len(declarationText) AndAlso _
       Asc(declarationText, localTagEnd) = Asc("{") Then
        Dim recordEnd As Long = localTagEnd
        If ScanSimpleExpressionGroup( _
            declarationText, recordEnd, Asc("{"), Asc("}")) = 0 Then _
            Return declarationText
        Dim recordBody As String = Mid( _
            declarationText, localTagEnd + 1, _
            recordEnd - localTagEnd - 2)
        Dim objectDeclaration As String = Trim(Mid(declarationText, recordEnd))
        If objectDeclaration = "" Then Return declarationText
        Dim objectParts() As String
        Dim objectPartCount As Long
        If SplitSimpleCList( _
            objectDeclaration, objectParts(), objectPartCount) = 0 OrElse _
           objectPartCount <> 1 Then Return declarationText
        Dim generatedRecordName As String
        If RegisterCBodyAnonymousRecord( _
            translation, catalog, recordBody, generatedRecordName, _
            recordKind) = 0 OrElse _
           RegisterSimpleBodyLocalType( _
               context, Mid(declarationText, tagStart, tagEnd - tagStart), _
               generatedRecordName) = 0 Then Return declarationText
        Dim prefix As String = Trim(Left(declarationText, recordStart - 1))
        If prefix <> "" Then prefix &= " "
        Return prefix & generatedRecordName & " " & objectDeclaration
    End If

    Dim fbRecord As String = SimpleBodyLocalType( _
        context, Mid(declarationText, tagStart, tagEnd - tagStart))
    If fbRecord = "" Then
        fbRecord = MappedFbBodyRecord( _
            translation, catalog, _
            Mid(declarationText, tagStart, tagEnd - tagStart))
    End If
    If fbRecord = "" Then Return declarationText
    While tagEnd <= Len(declarationText) AndAlso IsSpaceByte(Asc(declarationText, tagEnd)) <> 0
        tagEnd += 1
    Wend
    If tagEnd > Len(declarationText) Then Return declarationText
    If Asc(declarationText, tagEnd) <> Asc("{") Then
        ' Also normalize a separate file-scope record type used by a local
        ' variable, for example "struct unixFile *pFile". Pointer and array
        ' operators remain in the declarator for the ordinary C type parser.
        Dim objectDeclaration As String = Trim(Mid(declarationText, tagEnd))
        If objectDeclaration = "" Then Return declarationText
        Dim prefix As String = Trim(Left(declarationText, recordStart - 1))
        If prefix <> "" Then prefix &= " "
        Return prefix & fbRecord & " " & objectDeclaration
    End If
    Dim recordEnd As Long = tagEnd
    If ScanSimpleExpressionGroup(declarationText, recordEnd, Asc("{"), Asc("}")) = 0 Then _
        Return declarationText
    Dim objectDeclaration As String = Trim(Mid(declarationText, recordEnd))
    If objectDeclaration = "" Then Return declarationText
    Dim prefix As String = Trim(Left(declarationText, recordStart - 1))
    If prefix <> "" Then prefix &= " "
    Return prefix & fbRecord & " " & objectDeclaration
End Function

Private Function IsSupportedSimpleStaticPointerInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, _
    parameterNames() As String, ByVal symbolCount As Long, _
    ByVal variableType As String _
) As Long
    sourceExpression = GenericMacroStripOuterParentheses(Trim(sourceExpression))
    If sourceExpression = "" Then Return 0
    If GenericNullPointerConstantText(sourceExpression) <> 0 Then Return -1
    If Left(sourceExpression, 1) = Chr(34) Then Return -1

    Dim targetPointeeType As String = SimplePointeeType(variableType)
    If targetPointeeType = "Byte" OrElse targetPointeeType = "UByte" OrElse _
       targetPointeeType = "ZString" OrElse targetPointeeType = "Const ZString" OrElse _
       targetPointeeType = "c2fb_c_char" OrElse _
       targetPointeeType = "c2fb_c_uchar" Then
        Dim stringPosition As Long = InStr(sourceExpression, Chr(34))
        If stringPosition > 0 Then
            Dim prefix As String = Trim(Left(sourceExpression, stringPosition - 1))
            Dim stringValues As String
            Dim stringByteCount As Long
            If Left(prefix, 1) = "(" AndAlso Right(prefix, 1) = ")" AndAlso _
               ReadSimpleStaticStringArray( _
                   Mid(sourceExpression, stringPosition), _
                   stringValues, stringByteCount) <> 0 Then
                Dim typeText As String = Trim( _
                    Mid(prefix, 2, Len(prefix) - 2))
                Dim typeTokens() As String
                Dim typeTokenCount As Long
                TokenizeCDeclaration(typeText, typeTokens(), typeTokenCount)
                Dim sawCharacterType As Long = 0
                Dim castPointerCount As Long = 0
                Dim validCastType As Long = CInt(typeTokenCount > 0)
                For typeIndex As Long = 0 To typeTokenCount - 1
                    Select Case typeTokens(typeIndex)
                    Case "char"
                        sawCharacterType = -1
                    Case "signed", "unsigned", "const", "volatile", _
                         "restrict", "__restrict", "__restrict__"
                    Case "*"
                        castPointerCount += 1
                    Case Else
                        validCastType = 0
                    End Select
                Next
                If validCastType <> 0 AndAlso sawCharacterType <> 0 AndAlso _
                   castPointerCount = 1 Then Return -1
            End If
        End If
    End If

    Dim isAddress As Long = 0
    If Left(sourceExpression, 1) = "&" Then
        isAddress = -1
        sourceExpression = GenericMacroStripOuterParentheses( _
            Trim(Mid(sourceExpression, 2)))
    End If
    If IsIdentifierToken(sourceExpression) = 0 Then Return 0

    For i As Long = 0 To symbolCount - 1
        If parameterNames(i) = sourceExpression Then Return 0
    Next

    Dim externalObjectIndex As Long = _
        CBodyExternalObjectIndex(translation, sourceExpression)
    If externalObjectIndex >= 0 Then
        If isAddress <> 0 Then Return -1
        If translation.body.externalObjects(externalObjectIndex).isArray <> 0 Then _
            Return -1
        Return 0
    End If
    Return 0
End Function

Private Function IsSupportedSimpleStaticCallbackInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, _
    parameterNames() As String, ByVal symbolCount As Long, _
    callableNames() As String, ByVal callableCount As Long _
) As Long
    sourceExpression = GenericMacroStripOuterParentheses(Trim(sourceExpression))
    If sourceExpression = "" Then Return 0
    If GenericNullPointerConstantText(sourceExpression) <> 0 Then Return -1

    If Left(sourceExpression, 1) = "&" Then
        sourceExpression = GenericMacroStripOuterParentheses( _
            Trim(Mid(sourceExpression, 2)))
    End If
    If IsIdentifierToken(sourceExpression) = 0 Then Return 0

    For i As Long = 0 To symbolCount - 1
        If parameterNames(i) = sourceExpression Then Return 0
    Next
    If C2fbNameListContains( _
        callableNames(), callableCount, sourceExpression) <> 0 OrElse _
       CBodyProcedureIndex(translation, sourceExpression) >= 0 Then Return -1
    Return 0
End Function

Private Function ParseSimpleArrayDesignator( _
    ByRef translation As C2fbTranslationContext, _
    ByVal initializerText As String, _
    ByRef elementIndex As Long, _
    ByRef elementValue As String _
) As Long
    initializerText = Trim(initializerText)
    elementValue = initializerText
    If Left(initializerText, 1) <> "[" Then Return 0

    Dim bracketEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        initializerText, bracketEnd, Asc("["), Asc("]")) = 0 Then Return 0
    Dim indexExpression As String = Trim(Mid( _
        initializerText, 2, bracketEnd - 3))
    Dim position As Long = bracketEnd
    SkipCSpaces(initializerText, position)
    If position > Len(initializerText) OrElse _
       Asc(initializerText, position) <> Asc("=") Then Return 0
    position += 1
    elementValue = Trim(Mid(initializerText, position))
    If indexExpression = "" OrElse elementValue = "" Then Return 0

    If EvaluateSimpleArrayBound( _
           indexExpression, elementIndex, MAX_SIMPLE_ARRAY_COUNT, -1) = 0 AndAlso _
       EvaluateGenericBodyArrayBound( _
           translation, indexExpression, elementIndex, _
           MAX_SIMPLE_ARRAY_COUNT) = 0 Then Return 0
    If elementIndex < 0 OrElse _
       elementIndex >= MAX_SIMPLE_ARRAY_COUNT Then Return 0
    Return -1
End Function

Private Function ParseSimpleArrayRecordFieldDesignator( _
    ByRef translation As C2fbTranslationContext, _
    ByVal initializerText As String, _
    ByRef elementIndex As Long, ByRef fieldName As String, _
    ByRef fieldInitializer As String _
) As Long
    initializerText = Trim(initializerText)
    If Left(initializerText, 1) <> "[" Then Return 0

    Dim bracketEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        initializerText, bracketEnd, Asc("["), Asc("]")) = 0 Then Return 0
    Dim indexExpression As String = Trim(Mid( _
        initializerText, 2, bracketEnd - 3))
    Dim position As Long = bracketEnd
    SkipCSpaces(initializerText, position)
    If position > Len(initializerText) OrElse _
       Asc(initializerText, position) <> Asc(".") Then Return 0
    position += 1
    SkipCSpaces(initializerText, position)
    If position > Len(initializerText) OrElse _
       IsIdentifierStart(Asc(initializerText, position)) = 0 Then Return 0
    Dim fieldStart As Long = position
    position += 1
    While position <= Len(initializerText) AndAlso _
          IsIdentifierPart(Asc(initializerText, position)) <> 0
        position += 1
    Wend
    fieldName = Mid(initializerText, fieldStart, position - fieldStart)
    SkipCSpaces(initializerText, position)
    If position > Len(initializerText) OrElse _
       Asc(initializerText, position) <> Asc("=") Then Return 0
    position += 1
    fieldInitializer = Trim(Mid(initializerText, position))
    If indexExpression = "" OrElse fieldInitializer = "" Then Return 0

    If EvaluateSimpleArrayBound( _
           indexExpression, elementIndex, MAX_SIMPLE_ARRAY_COUNT, -1) = 0 AndAlso _
       EvaluateGenericBodyArrayBound( _
           translation, indexExpression, elementIndex, _
           MAX_SIMPLE_ARRAY_COUNT) = 0 Then Return 0
    If elementIndex < 0 OrElse _
       elementIndex >= MAX_SIMPLE_ARRAY_COUNT Then Return 0
    Return -1
End Function

Private Function LowerSimpleArrayInitializerDesignators( _
    ByRef translation As C2fbTranslationContext, _
    ByRef context As SimpleBodyContext, values() As String, _
    ByRef valueCount As Long, ByVal arrayCount As Long, _
    ByVal isRecordArray As Long, ByRef hasArrayDesignator As Long _
) As Long
    hasArrayDesignator = 0
    For valueIndex As Long = 0 To valueCount - 1
        If Left(Trim(values(valueIndex)), 1) = "[" Then
            hasArrayDesignator = -1
            Exit For
        End If
    Next
    If hasArrayDesignator = 0 Then Return -1
    If arrayCount <= 0 OrElse arrayCount > MAX_SIMPLE_ARRAY_COUNT Then _
        Return 0

    Dim sourceValues() As String
    ReDim sourceValues(0 To valueCount - 1)
    For valueIndex As Long = 0 To valueCount - 1
        sourceValues(valueIndex) = values(valueIndex)
    Next
    ReDim values(0 To arrayCount - 1)
    Dim initializedElements() As Long
    ReDim initializedElements(0 To arrayCount - 1)
    Dim recordFieldInitializers() As String
    ReDim recordFieldInitializers(0 To arrayCount - 1)
    Dim hasRecordFieldDesignator As Long = 0
    Dim nextElementIndex As Long = 0

    For sourceIndex As Long = 0 To UBound(sourceValues)
        Dim elementValue As String = Trim(sourceValues(sourceIndex))
        Dim currentElementIndex As Long = nextElementIndex
        If Left(elementValue, 1) = "[" Then
            Dim fieldName As String
            Dim fieldInitializer As String
            If isRecordArray <> 0 AndAlso _
               ParseSimpleArrayRecordFieldDesignator( _
                   translation, elementValue, currentElementIndex, _
                   fieldName, fieldInitializer) <> 0 Then
                If currentElementIndex < 0 OrElse _
                   currentElementIndex >= arrayCount OrElse _
                   initializedElements(currentElementIndex) = 1 Then
                    RecordSimpleBodyFailure( _
                        context, "invalid-static-record-array-designator", _
                        "out-of-range or conflicting record array designator: " & _
                        Trim(Str(currentElementIndex)))
                    Return 0
                End If
                If recordFieldInitializers(currentElementIndex) <> "" Then _
                    recordFieldInitializers(currentElementIndex) &= ", "
                recordFieldInitializers(currentElementIndex) &= _
                    "." & fieldName & " = " & fieldInitializer
                initializedElements(currentElementIndex) = 2
                hasRecordFieldDesignator = -1
                nextElementIndex = currentElementIndex + 1
                Continue For
            End If

            Dim designatedValue As String
            If ParseSimpleArrayDesignator( _
                translation, elementValue, currentElementIndex, _
                designatedValue) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-static-array-designator", _
                    "unsupported local array designator: " & _
                    Left(elementValue, 120))
                Return 0
            End If
            elementValue = designatedValue
        ElseIf hasRecordFieldDesignator <> 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-static-record-array-initializer-order", _
                "a record-field designator must be followed by another indexed designator")
            Return 0
        End If

        If currentElementIndex < 0 OrElse _
           currentElementIndex >= arrayCount OrElse _
           initializedElements(currentElementIndex) <> 0 Then
            RecordSimpleBodyFailure( _
                context, "invalid-static-array-designator", _
                "out-of-range or repeated local array index: " & _
                Trim(Str(currentElementIndex)))
            Return 0
        End If
        values(currentElementIndex) = elementValue
        initializedElements(currentElementIndex) = 1
        nextElementIndex = currentElementIndex + 1
    Next

    For elementIndex As Long = 0 To arrayCount - 1
        If initializedElements(elementIndex) = 0 Then
            values(elementIndex) = ""
        ElseIf initializedElements(elementIndex) = 2 Then
            values(elementIndex) = "{" & _
                recordFieldInitializers(elementIndex) & "}"
        End If
    Next
    valueCount = arrayCount
    Return -1
End Function

Private Function NormalizeGenericBoundLocalSizeof( _
    ByVal sourceExpression As String, _
    locals() As SimpleLocalVariable, ByVal localCount As Long, _
    ByRef normalizedExpression As String _
) As Long
    normalizedExpression = ""
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        If Mid(sourceExpression, position, Len("sizeof")) = "sizeof" AndAlso _
           (position = 1 OrElse _
            IsIdentifierPart(Asc(sourceExpression, position - 1)) = 0) Then
            Dim operandPosition As Long = position + Len("sizeof")
            If operandPosition <= Len(sourceExpression) AndAlso _
               IsIdentifierPart(Asc(sourceExpression, operandPosition)) <> 0 Then
                normalizedExpression &= Mid(sourceExpression, position, 1)
                position += 1
                Continue While
            End If
            SkipCSpaces(sourceExpression, operandPosition)
            Dim operandName As String
            Dim operandEnd As Long = operandPosition
            If operandPosition <= Len(sourceExpression) AndAlso _
               Asc(sourceExpression, operandPosition) = Asc("(") Then
                If ScanSimpleExpressionGroup( _
                    sourceExpression, operandEnd, Asc("("), Asc(")")) <> 0 Then
                    Dim operandText As String = Trim(Mid( _
                        sourceExpression, operandPosition + 1, _
                        operandEnd - operandPosition - 2))
                    If IsIdentifierToken(operandText) <> 0 Then _
                        operandName = operandText
                End If
            ElseIf operandPosition <= Len(sourceExpression) AndAlso _
                   IsIdentifierStart(Asc(sourceExpression, operandPosition)) <> 0 Then
                operandEnd += 1
                While operandEnd <= Len(sourceExpression) AndAlso _
                      IsIdentifierPart(Asc(sourceExpression, operandEnd)) <> 0
                    operandEnd += 1
                Wend
                operandName = Mid( _
                    sourceExpression, operandPosition, _
                    operandEnd - operandPosition)
            End If
            If operandName <> "" Then
                For localIndex As Long = localCount - 1 To 0 Step -1
                    If locals(localIndex).name <> operandName OrElse _
                       locals(localIndex).hasKnownSize = 0 Then Continue For
                    normalizedExpression &= Trim(Str( _
                        locals(localIndex).sizeofBytes))
                    position = operandEnd
                    Exit For
                Next
                If position = operandEnd Then Continue While
            End If
        End If
        normalizedExpression &= Mid(sourceExpression, position, 1)
        position += 1
    Wend
    Return -1
End Function

' Keep this form narrow: static pointer arrays are accepted for known string
' storage, null-pointer constants, or zero-filled storage without an initializer.
Private Function IsSimpleNullPointerInitializer( _
    ByVal initializerText As String _
) As Long
    initializerText = Trim(initializerText)
    If Left(initializerText, 1) <> "{" OrElse _
       Right(initializerText, 1) <> "}" Then Return 0
    initializerText = Trim(Mid( _
        initializerText, 2, Len(initializerText) - 2))
    If Right(initializerText, 1) = "," Then _
        initializerText = RTrim(Left(initializerText, Len(initializerText) - 1))
    Dim values() As String
    Dim valueCount As Long
    If SplitSimpleCList(initializerText, values(), valueCount) = 0 OrElse _
       valueCount = 0 Then Return 0
    For valueIndex As Long = 0 To valueCount - 1
        Dim valueText As String = Trim(values(valueIndex))
        If SimpleZeroIntegerExpression(valueText) <> 0 Then Continue For
        While Len(valueText) >= 2 AndAlso Left(valueText, 1) = "(" AndAlso _
              Right(valueText, 1) = ")"
            Dim outerEnd As Long = 1
            If ScanSimpleExpressionGroup( _
                valueText, outerEnd, Asc("("), Asc(")")) = 0 OrElse _
               outerEnd <> Len(valueText) + 1 Then Exit While
            valueText = Trim(Mid(valueText, 2, Len(valueText) - 2))
        Wend
        If Left(valueText, 1) <> "(" Then Return 0
        Dim castEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            valueText, castEnd, Asc("("), Asc(")")) = 0 Then Return 0
        Dim castType As String = Trim(Mid(valueText, 2, castEnd - 2))
        Dim castValue As String = Trim(Mid(valueText, castEnd))
        If InStr(castType, "*") = 0 OrElse _
           SimpleZeroIntegerExpression(castValue) = 0 Then Return 0
    Next
    Return -1
End Function

Private Function NormalizeSimpleRawCallbackArrayDeclaration( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceDeclaration As String, _
    ByRef normalizedDeclaration As String _
) As Long
    normalizedDeclaration = ""
    If InStr(sourceDeclaration, "static") = 0 OrElse _
       InStr(sourceDeclaration, "[") = 0 Then Return 0

    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceDeclaration, tokens(), tokenCount)
    If tokenCount < 6 OrElse tokenCount >= MAX_C_DECLARATION_TOKENS Then Return 0

    For candidateStart As Long = 1 To tokenCount - 2
        If IsCFunctionReturnTypePrefix( _
            tokens(), 0, candidateStart - 1) = 0 Then Continue For
        Dim declaratorPosition As Long = candidateStart
        Dim declarator As C2fbDeclaratorModel
        If ParseCDeclaratorModel( _
            tokens(), declaratorPosition, tokenCount - 1, declarator, 0, 0) = 0 OrElse _
           declaratorPosition <> tokenCount OrElse _
           IsIdentifierToken(declarator.name) = 0 OrElse _
           declarator.firstFunctionOpenToken < 0 Then Continue For

        Dim pointerCount As Long = 0
        Dim arrayCountInType As Long = 0
        Dim functionCount As Long = 0
        For operatorIndex As Long = 0 To declarator.operatorCount - 1
            Select Case declarator.operatorKind(operatorIndex)
            Case C2FB_DECLARATOR_POINTER: pointerCount += 1
            Case C2FB_DECLARATOR_ARRAY: arrayCountInType += 1
            Case C2FB_DECLARATOR_FUNCTION: functionCount += 1
            Case Else: Exit For
            End Select
        Next
        If pointerCount <> 1 OrElse arrayCountInType <> 1 OrElse _
           functionCount <> 1 Then Continue For

        Dim arrayOpen As Long = -1
        For tokenIndex As Long = declarator.nameTokenIndex + 1 To _
            declarator.firstFunctionOpenToken - 1
            If tokens(tokenIndex) = "[" Then
                arrayOpen = tokenIndex
                Exit For
            End If
        Next
        If arrayOpen < 0 Then Continue For
        Dim arrayPosition As Long = arrayOpen
        If SkipCDeclaratorGroup( _
            tokens(), arrayPosition, declarator.firstFunctionOpenToken - 1, _
            "[", "]") = 0 Then Continue For
        Dim arrayClose As Long = arrayPosition - 1

        Dim arrayBound As String
        For tokenIndex As Long = arrayOpen + 1 To arrayClose - 1
            arrayBound &= tokens(tokenIndex)
        Next

        Dim callbackTokens() As String
        ReDim callbackTokens(0 To tokenCount - 1)
        Dim callbackTokenCount As Long = 0
        For tokenIndex As Long = 0 To tokenCount - 1
            If tokenIndex = arrayOpen Then
                tokenIndex = arrayClose
                Continue For
            End If
            callbackTokens(callbackTokenCount) = tokens(tokenIndex)
            callbackTokenCount += 1
        Next
        If callbackTokenCount < 4 Then Continue For

        Dim callbackResult As C2fbCallbackTypeResultModel
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, callbackTokens(), 0, _
            callbackTokenCount - 1, callbackResult, 0, C2FB_TYPE_MAPPING_BODY)
        If callbackResult.status <> C2FB_CALLBACK_TYPE_CONVERTED OrElse _
           callbackResult.callbackName <> declarator.name OrElse _
           callbackResult.pointerDepth <> 1 OrElse _
           callbackResult.freeBasicType = "" Then Return 0

        Dim pointerIsConst As Long = 0
        For tokenIndex As Long = candidateStart To _
            declarator.firstFunctionOpenToken - 1
            If tokens(tokenIndex) = "const" Then
                pointerIsConst = -1
                Exit For
            End If
        Next
        normalizedDeclaration = "static " & callbackResult.freeBasicType
        If pointerIsConst <> 0 Then normalizedDeclaration &= " const"
        normalizedDeclaration &= " " & declarator.name & "[" & arrayBound & "]"
        Return -1
    Next
    Return 0
End Function

Private Function TranslateSingleDeclarationStatementWithTokens( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, _
    sourceTokens() As String, ByVal sourceTokenCount As Long, _
    ByRef outputText As String, _
    ByRef context As SimpleBodyContext, _
    locals() As SimpleLocalVariable, _
    ByRef localCount As Long, _
    callableNames() As String, _
    ByVal callableCount As Long, _
    parameterNames() As String, _
    parameterAliases() As String, _
    parameterTypes() As String, _
    ByRef symbolCount As Long, _
    ByVal alignmentValue As Long _
) As Long
    outputText = ""
    If Len(statementText) = 0 Then Return 0
    Dim equalsPosition As Long = FindSimpleAssignmentEquals(statementText)
    Dim declarationText As String = statementText
    If equalsPosition > 0 Then declarationText = Trim(Left(statementText, equalsPosition - 1))
    Dim originalDeclarationText As String = declarationText
    Dim normalizedCallbackArrayDeclaration As String
    Dim normalizedRawCallbackArray As Long = 0
    If NormalizeSimpleRawCallbackArrayDeclaration( _
        translation, catalog, declarationText, _
        normalizedCallbackArrayDeclaration) <> 0 Then
        declarationText = normalizedCallbackArrayDeclaration
        normalizedRawCallbackArray = -1
    Else
        declarationText = NormalizeCInlineRecordArrayDeclaration( _
            translation, catalog, context, declarationText)
    End If

    Dim tokens() As String
    ' Array bounds and initializers can use the full declaration token limit.
    If sourceTokenCount < 2 OrElse _
       sourceTokenCount >= MAX_C_DECLARATION_TOKENS Then Return 0
    ReDim tokens(0 To sourceTokenCount - 1)
    For tokenIndex As Long = 0 To sourceTokenCount - 1
        tokens(tokenIndex) = sourceTokens(tokenIndex)
    Next
    ' The original statement keeps its initializer text. Only declarator tokens
    ' enter the bounded type and name analysis buffers.
    Dim tokenCount As Long = sourceTokenCount
    If tokens(tokenCount - 1) = ";" Then tokenCount -= 1
    Dim assignmentToken As Long
    If FindC2fbTopLevelAssignmentToken( _
        tokens(), 0, tokenCount - 1, assignmentToken) = 0 Then Return 0
    If assignmentToken >= 0 Then tokenCount = assignmentToken
    If declarationText <> originalDeclarationText Then
        TokenizeCDeclaration(declarationText, tokens(), tokenCount)
    End If
    If tokenCount < 2 Then Return 0
    Dim callbackResult As C2fbCallbackTypeResultModel
    If normalizedRawCallbackArray <> 0 Then
        callbackResult.status = C2FB_CALLBACK_TYPE_NOT_CALLBACK
    Else
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, tokens(), 0, tokenCount - 1, _
            callbackResult, 0, C2FB_TYPE_MAPPING_BODY, -1)
    End If
    If callbackResult.status = C2FB_CALLBACK_TYPE_UNSUPPORTED Then Return 0
    If callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED AndAlso _
       callbackResult.callbackName <> "" Then
        Dim callbackName As String = callbackResult.callbackName
        Dim callbackType As String = callbackResult.freeBasicType
        Dim isStaticCallback As Long = _
            CInt(InStr(declarationText, "static") <> 0)
        If callbackResult.pointerDepth < 1 OrElse _
           callbackResult.pointerDepth > MAX_FREEBASIC_POINTER_LEVELS Then Return 0
        ' The callback alias already represents the function-pointer layer;
        ' retain any outer C pointers, such as a callback pointer passed as void *.
        For pointerLevel As Long = 2 To callbackResult.pointerDepth
            callbackType &= " Ptr"
        Next
        Dim callbackInitializer As String = ""
        Dim callbackInitializerPrelude As String
        If equalsPosition > 0 Then
            callbackInitializer = Trim(Mid(statementText, equalsPosition + 1))
            If isStaticCallback <> 0 AndAlso _
               IsSupportedSimpleStaticCallbackInitializer( _
                   translation, callbackInitializer, parameterNames(), _
                   symbolCount, callableNames(), callableCount) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-static-callback-initializer", _
                    "unsupported static callback initializer: " & _
                    Left(statementText, 160))
                Return 0
            End If
            Dim translatedInitializer As String
            If isStaticCallback <> 0 Then
                Dim initializerHasBoolean As Long
                Dim initializerHasCall As Long
                If TranslateSimpleExpression( _
                    translation, catalog, callbackInitializer, _
                    translatedInitializer, initializerHasBoolean, _
                    initializerHasCall, callableNames(), callableCount, _
                    parameterNames(), parameterAliases(), parameterTypes(), _
                    symbolCount, callbackType) = 0 OrElse _
                   initializerHasCall <> 0 Then Return 0
            ElseIf TranslateSequencedExpression( _
                translation, catalog, callbackInitializer, translatedInitializer, _
                callbackInitializerPrelude, context, callableNames(), _
                callableCount, parameterNames(), parameterAliases(), _
                parameterTypes(), symbolCount, callbackType) = 0 Then
                Return 0
            End If
            callbackInitializer = translatedInitializer
        End If
        Dim scopeStart As Long = context.scopeSymbols(context.scopeDepth - 1)
        For i As Long = scopeStart To symbolCount - 1
            If parameterNames(i) = callbackName Then Return 0
        Next
        If context.localSerial >= MAX_SIMPLE_VARIABLES OrElse _
           localCount >= MAX_SIMPLE_VARIABLES OrElse _
           symbolCount >= MAX_SIMPLE_VARIABLES Then Return 0
        locals(localCount).name = callbackName
        locals(localCount).typeName = callbackType
        locals(localCount).isConst = 0
        locals(localCount).sizeofBytes = CLng(SizeOf(Any Ptr))
        locals(localCount).hasKnownSize = -1
        locals(localCount).isIntegerConstant = 0
        locals(localCount).integerValue = 0
        localCount += 1
        parameterNames(symbolCount) = callbackName
        parameterAliases(symbolCount) = "local" & Trim(Str(context.localSerial))
        context.localSerial += 1
        parameterTypes(symbolCount) = callbackType
        If isStaticCallback <> 0 Then
            context.declarations &= "    Static " & parameterAliases(symbolCount) & _
                " As " & callbackType
            If equalsPosition > 0 Then _
                context.declarations &= " = " & callbackInitializer
            context.declarations &= Chr(10)
        Else
            context.declarations &= "    Dim " & parameterAliases(symbolCount) & _
                " As " & callbackType & Chr(10)
        End If
        symbolCount += 1
        If isStaticCallback = 0 AndAlso equalsPosition > 0 Then
            ' Automatic C initializers run when control reaches the declaration.
            ' Keep the storage declaration at procedure scope and execute the
            ' sequenced callback initializer at its original statement point.
            If callbackInitializerPrelude <> "" Then _
                outputText = RTrim( _
                    callbackInitializerPrelude, Any Chr(10)) & Chr(10)
            outputText &= parameterAliases(symbolCount - 1) & " = " & _
                          callbackInitializer
        Else
            outputText = IIf( _
                isStaticCallback <> 0, "' C static callback storage", _
                "' C automatic callback storage declaration")
        End If
        Return -1
    End If
    Dim nameIndex As Long = tokenCount - 1
    Dim arrayCount As Long = 0
    Dim arrayBound As String
    Dim arrayRank As Long = 0
    Dim arrayDimensions As String
    Dim arrayDimensionBounds() As String
    Dim arrayDimensionCounts() As Long
    Dim isSymbolicArrayBound As Long = 0
    Dim isDynamicLocalArray As Long = 0
    Dim localArrayTypedefAliasIndex As Long = -1
    Dim dynamicBoundName As String
    Dim dynamicBoundExpression As String
    Dim dynamicBoundPrelude As String
    Dim isStaticLocal As Long = 0
    Dim isConstLocal As Long = 0
    Dim staticStringValues As String
    Dim staticStringByteCount As Long = 0
    Dim staticStringInitializer As Long = 0
    For i As Long = 0 To tokenCount - 1
        If tokens(i) = "static" Then isStaticLocal = -1
        If tokens(i) = "const" Then isConstLocal = -1
    Next
    Dim maximumLocalArrayCount As Long = MAX_SIMPLE_ARRAY_COUNT
    If isStaticLocal <> 0 AndAlso equalsPosition = 0 Then _
        maximumLocalArrayCount = MAX_STATIC_LOCAL_ARRAY_COUNT
    Dim openingBracket As Long = -1
    For i As Long = 0 To tokenCount - 1
        If tokens(i) = "[" Then
            openingBracket = i
            Exit For
        End If
    Next
    If openingBracket >= 0 Then
        nameIndex = openingBracket - 1
        Dim bracketPosition As Long = InStr(declarationText, "[")
        Dim bracketEndPosition As Long = bracketPosition
        If bracketPosition = 0 OrElse _
           ScanSimpleExpressionGroup( _
               declarationText, bracketEndPosition, Asc("["), Asc("]")) = 0 Then _
            Return 0
        Dim countText As String = Trim(Mid( _
            declarationText, bracketPosition + 1, _
            bracketEndPosition - bracketPosition - 2))
        Dim arrayDimensionCount As Long = 0
        Dim dimensionOpenToken As Long = openingBracket
        While dimensionOpenToken < tokenCount AndAlso _
              tokens(dimensionOpenToken) = "["
            Dim closingBracketToken As Long = -1
            Dim nestedBracketDepth As Long = 0
            For tokenIndex As Long = dimensionOpenToken + 1 To tokenCount - 1
                If tokens(tokenIndex) = "[" Then
                    nestedBracketDepth += 1
                ElseIf tokens(tokenIndex) = "]" Then
                    If nestedBracketDepth = 0 Then
                        closingBracketToken = tokenIndex
                        Exit For
                    End If
                    nestedBracketDepth -= 1
                End If
            Next
            If closingBracketToken < 0 Then Return 0
            arrayDimensionCount += 1
            dimensionOpenToken = closingBracketToken + 1
        Wend
        If arrayDimensionCount <= 0 OrElse dimensionOpenToken <> tokenCount OrElse _
           arrayDimensionCount > MAX_GENERIC_ARRAY_RANK Then Return 0

        If arrayDimensionCount > 1 Then
            Dim canInferStringRowCount As Long = CInt( _
                arrayDimensionCount = 2 AndAlso isStaticLocal <> 0 AndAlso _
                equalsPosition <> 0)
            Dim hasCharElementType As Long = 0
            For typeToken As Long = 0 To openingBracket - 1
                If tokens(typeToken) = "char" Then hasCharElementType = -1
                If tokens(typeToken) = "*" Then canInferStringRowCount = 0
            Next
            canInferStringRowCount = CInt( _
                canInferStringRowCount <> 0 AndAlso hasCharElementType <> 0)
            Dim hasUnsizedLeadingDimension As Long = 0
            ReDim arrayDimensionBounds(0 To arrayDimensionCount - 1)
            ReDim arrayDimensionCounts(0 To arrayDimensionCount - 1)
            Dim dimensionTextPosition As Long = bracketPosition
            Dim totalArrayCount As LongInt = 1
            Dim hasDynamicDimension As Long = 0
            For dimensionIndex As Long = 0 To arrayDimensionCount - 1
                SkipCSpaces(declarationText, dimensionTextPosition)
                Dim dimensionEndPosition As Long = dimensionTextPosition
                If ScanSimpleExpressionGroup( _
                    declarationText, dimensionEndPosition, _
                    Asc("["), Asc("]")) = 0 Then Return 0
                Dim dimensionText As String = Trim(Mid( _
                    declarationText, dimensionTextPosition + 1, _
                    dimensionEndPosition - dimensionTextPosition - 2))
                Dim normalizedDimensionText As String
                NormalizeGenericBoundLocalSizeof( _
                    dimensionText, locals(), localCount, normalizedDimensionText)
                dimensionText = normalizedDimensionText
                Dim dimensionCount As Long
                If dimensionText = "" Then
                    If dimensionIndex <> 0 OrElse canInferStringRowCount = 0 Then Return 0
                    hasUnsizedLeadingDimension = -1
                    arrayDimensionCounts(dimensionIndex) = 0
                    arrayDimensionBounds(dimensionIndex) = ""
                ElseIf EvaluateSimpleArrayBound( _
                    dimensionText, dimensionCount, MAX_GENERIC_ARRAY_COUNT) <> 0 OrElse _
                   EvaluateGenericBodyArrayBound( _
                       translation, dimensionText, dimensionCount, _
                       MAX_GENERIC_ARRAY_COUNT) <> 0 Then
                    arrayDimensionCounts(dimensionIndex) = dimensionCount
                    arrayDimensionBounds(dimensionIndex) = _
                        Trim(Str(dimensionCount)) & "ULL"
                    If hasDynamicDimension = 0 Then
                        If totalArrayCount > _
                           (MAX_GENERIC_ARRAY_COUNT \ dimensionCount) Then Return 0
                        totalArrayCount *= dimensionCount
                    End If
                Else
                    If isStaticLocal <> 0 OrElse equalsPosition <> 0 Then Return 0
                    ' Evaluate each VLA dimension at the declaration site.
                    ' Emit its prelude before capturing the bound so supported
                    ' updates stay at this C execution point.
                    Dim loweredDimensionBound As String
                    Dim dimensionBoundPrelude As String
                    If TranslateSequencedExpression( _
                        translation, catalog, dimensionText, _
                        loweredDimensionBound, dimensionBoundPrelude, context, _
                        callableNames(), callableCount, _
                        parameterNames(), parameterAliases(), parameterTypes(), _
                        symbolCount, "LongInt") = 0 Then Return 0
                    Dim dimensionBoundName As String = NewSimpleBodyTemporary( _
                        context, "LongInt", "")
                    If dimensionBoundName = "" Then Return 0
                    If dimensionBoundPrelude <> "" Then _
                        dynamicBoundPrelude &= _
                            RTrim(dimensionBoundPrelude, Any Chr(10)) & Chr(10)
                    dynamicBoundPrelude &= dimensionBoundName & " = " & _
                        loweredDimensionBound & Chr(10) & _
                        "If " & dimensionBoundName & " <= 0 OrElse " & _
                        dimensionBoundName & " > " & _
                        Trim(Str(MAX_GENERIC_ARRAY_COUNT)) & " Then Error 5" & Chr(10)
                    arrayDimensionBounds(dimensionIndex) = dimensionBoundName
                    arrayDimensionCounts(dimensionIndex) = 0
                    hasDynamicDimension = -1
                End If
                If dimensionIndex > 0 Then arrayDimensions &= ","
                arrayDimensions &= arrayDimensionBounds(dimensionIndex)
                dimensionTextPosition = dimensionEndPosition
            Next
            arrayRank = arrayDimensionCount
            ' A const-qualified automatic array still has ordinary C storage;
            ' the expression model enforces read-only access through its alias.
            ' Keep the FreeBASIC backing array mutable so ReDim can represent a VLA.
            If hasDynamicDimension <> 0 Then
                If equalsPosition <> 0 Then Return 0
                dynamicBoundName = NewSimpleBodyTemporary(context, "LongInt", "")
                If dynamicBoundName = "" Then Return 0
                dynamicBoundPrelude &= dynamicBoundName & " = " & _
                    arrayDimensionBounds(0) & Chr(10)
                For dimensionIndex As Long = 1 To arrayDimensionCount - 1
                    dynamicBoundPrelude &= _
                        "If " & dynamicBoundName & " > " & _
                        Trim(Str(MAX_GENERIC_ARRAY_COUNT)) & " \ " & _
                        arrayDimensionBounds(dimensionIndex) & _
                        " Then Error 5" & Chr(10) & _
                        dynamicBoundName & " *= " & _
                        arrayDimensionBounds(dimensionIndex) & Chr(10)
                Next
                dynamicBoundExpression = ""
                arrayBound = dynamicBoundName
                isSymbolicArrayBound = -1
                isDynamicLocalArray = -1
            ElseIf hasUnsizedLeadingDimension <> 0 Then
                If arrayDimensionCounts(1) < 1 Then Return 0
                Dim initializerText As String = Trim(Mid( _
                    statementText, equalsPosition + 1))
                Dim stringRowCount As Long
                Dim stringMatrixByteCount As Long
                If ReadSimpleStaticStringMatrix( _
                    initializerText, arrayDimensionCounts(1), _
                    staticStringValues, stringRowCount, _
                    stringMatrixByteCount) = 0 Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-static-string-matrix", _
                        "unsupported static string-matrix initializer: " & _
                        Left(statementText, 160))
                    Return 0
                End If
                arrayDimensionCounts(0) = stringRowCount
                arrayDimensionBounds(0) = Trim(Str(stringRowCount)) & "ULL"
                arrayDimensions = arrayDimensionBounds(0) & "," & _
                                 arrayDimensionBounds(1)
                arrayCount = stringMatrixByteCount
                arrayBound = Trim(Str(arrayCount)) & "ULL"
                staticStringByteCount = arrayCount
                staticStringInitializer = -1
            ElseIf totalArrayCount <= MAX_SIMPLE_ARRAY_COUNT Then
                arrayCount = CLng(totalArrayCount)
                arrayBound = Trim(Str(arrayCount)) & "ULL"
            Else
                If isStaticLocal <> 0 OrElse _
                   (equalsPosition <> 0 AndAlso _
                    totalArrayCount > MAX_DYNAMIC_ARRAY_INITIALIZER_COUNT) Then _
                    Return 0
                dynamicBoundExpression = Trim(Str(totalArrayCount))
                dynamicBoundName = NewSimpleBodyTemporary( _
                    context, "LongInt", "")
                If dynamicBoundName = "" Then Return 0
                If equalsPosition <> 0 Then arrayCount = CLng(totalArrayCount)
                arrayBound = dynamicBoundName
                isSymbolicArrayBound = -1
                isDynamicLocalArray = -1
            End If
        Else
            If countText = "" Then
                If equalsPosition = 0 Then Return 0
                Dim initializerText As String = Trim(Mid(statementText, equalsPosition + 1))
                If Left(initializerText, 1) = Chr(34) Then
                    ' Infer the C array extent from every adjacent string literal,
                    ' including its NUL. Automatic storage is initialized each time
                    ' execution reaches this declaration below.
                    If ReadSimpleStaticStringArray(initializerText, staticStringValues, _
                                                   staticStringByteCount) = 0 Then Return 0
                    staticStringInitializer = -1
                    arrayCount = staticStringByteCount
                ElseIf Left(initializerText, 1) = "{" AndAlso Right(initializerText, 1) = "}" Then
                    Dim initialValues() As String
                    Dim initialValueCount As Long
                    Dim initialText As String = Trim(Mid(initializerText, 2, Len(initializerText) - 2))
                    If Right(initialText, 1) = "," Then _
                        initialText = RTrim(Left(initialText, Len(initialText) - 1))
                    If SplitSimpleCList(initialText, initialValues(), initialValueCount) = 0 Then Return 0
                    Dim nextElementIndex As Long = 0
                    Dim maximumElementIndex As Long = -1
                    For valueIndex As Long = 0 To initialValueCount - 1
                        Dim currentElementIndex As Long = nextElementIndex
                        Dim elementValue As String = Trim(initialValues(valueIndex))
                        If Left(elementValue, 1) = "[" Then
                            Dim designatedValue As String
                            If ParseSimpleArrayDesignator( _
                                translation, elementValue, currentElementIndex, _
                                designatedValue) = 0 Then Return 0
                        End If
                        If currentElementIndex > maximumElementIndex Then _
                            maximumElementIndex = currentElementIndex
                        nextElementIndex = currentElementIndex + 1
                    Next
                    arrayCount = maximumElementIndex + 1
                    If arrayCount <= 0 Then Return 0
                Else
                    Return 0
                End If
            Else
                Dim normalizedCountText As String
                NormalizeGenericBoundLocalSizeof( _
                    countText, locals(), localCount, normalizedCountText)
                countText = normalizedCountText
                If EvaluateSimpleArrayBound( _
                    countText, arrayCount, maximumLocalArrayCount) = 0 AndAlso _
                   EvaluateGenericBodyArrayBound( _
                       translation, countText, arrayCount, _
                       maximumLocalArrayCount) = 0 Then
                Dim oversizedConstantArrayCount As Long
                If EvaluateSimpleArrayBound( _
                    countText, oversizedConstantArrayCount, _
                    MAX_GENERIC_ARRAY_COUNT) <> 0 Then
                    If oversizedConstantArrayCount <= MAX_SIMPLE_ARRAY_COUNT OrElse _
                       isStaticLocal <> 0 OrElse isConstLocal <> 0 OrElse _
                       (equalsPosition <> 0 AndAlso _
                        oversizedConstantArrayCount > _
                            MAX_DYNAMIC_ARRAY_INITIALIZER_COUNT) Then Return 0
                    ' Large fixed automatic arrays use managed storage instead
                    ' of exhausting the compiler's bounded inline-array path.
                    dynamicBoundExpression = Trim(Str(oversizedConstantArrayCount))
                    If equalsPosition <> 0 Then _
                        arrayCount = oversizedConstantArrayCount
                Else
                    Dim loweredSourceBound As String = LCase(countText)
                    If InStr(loweredSourceBound, "sizeof") = 0 AndAlso _
                       InStr(loweredSourceBound, "__builtin_offsetof") = 0 Then
                        Dim boundTokens() As String
                        Dim boundTokenCount As Long
                        TokenizeCDeclaration( _
                            countText, boundTokens(), boundTokenCount)
                        Dim hasIdentifierBound As Long = 0
                        Dim previousTokenIsInteger As Long = 0
                        For boundTokenIndex As Long = 0 To boundTokenCount - 1
                            Dim boundToken As String = boundTokens(boundTokenIndex)
                            Dim lowerBoundToken As String = LCase(boundToken)
                            If IsIdentifierToken(boundToken) <> 0 Then
                                Select Case lowerBoundToken
                                Case "u", "l", "ll", "ul", "lu", "ull", "llu"
                                    If previousTokenIsInteger <> 0 Then
                                        previousTokenIsInteger = 0
                                        Continue For
                                    End If
                                End Select
                                hasIdentifierBound = -1
                            End If
                            Dim firstBoundByte As Long = Asc(boundToken, 1)
                            previousTokenIsInteger = CInt( _
                                firstBoundByte >= Asc("0") AndAlso _
                                firstBoundByte <= Asc("9"))
                        Next
                        If hasIdentifierBound = 0 Then Return 0
                    End If
                    ' A C VLA evaluates its bound at the declaration point.
                    ' Retain that single result for later sizeof operations.
                    If equalsPosition <> 0 OrElse isStaticLocal <> 0 Then Return 0
                    If TranslateSequencedExpression( _
                        translation, catalog, countText, _
                        dynamicBoundExpression, dynamicBoundPrelude, context, _
                        callableNames(), callableCount, parameterNames(), _
                        parameterAliases(), parameterTypes(), symbolCount, "LongInt") = 0 Then _
                        Return 0
                End If
                dynamicBoundName = NewSimpleBodyTemporary(context, "LongInt", "")
                If dynamicBoundName = "" Then Return 0
                arrayBound = dynamicBoundName
                isSymbolicArrayBound = -1
                isDynamicLocalArray = -1
                End If
            End If
            arrayRank = 1
            arrayDimensions = arrayBound
        End If
        If isSymbolicArrayBound = 0 Then
            If arrayCount < 1 OrElse _
               arrayCount > maximumLocalArrayCount Then Return 0
            arrayBound = Trim(Str(arrayCount)) & "ULL"
        ElseIf arrayBound = "" Then
            Return 0
        End If
        If arrayDimensionCount = 1 Then arrayDimensions = arrayBound
    End If
    If openingBracket >= 0 AndAlso arrayRank = 1 AndAlso _
       equalsPosition > 0 AndAlso staticStringInitializer = 0 Then
        Dim hasPointerElement As Long = 0
        Dim hasCharacterElement As Long = 0
        For typeToken As Long = 0 To openingBracket - 1
            If tokens(typeToken) = "*" Then hasPointerElement = -1
            If tokens(typeToken) = "char" Then hasCharacterElement = -1
        Next
        If hasPointerElement = 0 AndAlso hasCharacterElement <> 0 Then
            Dim stringInitializer As String = Trim(Mid( _
                statementText, equalsPosition + 1))
            If Left(stringInitializer, 1) = Chr(34) Then
                If ReadSimpleCharArrayStringInitializer( _
                    stringInitializer, arrayCount, staticStringValues, _
                    staticStringByteCount) = 0 Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-character-array-string-initializer", _
                        "character array string initializer exceeds its declared bound: " & _
                        Left(statementText, 160))
                    Return 0
                End If
                staticStringInitializer = -1
            End If
        End If
    End If
    Dim localArrayTypeName As String = ""
    Dim localArrayTypeNameIsAmbiguous As Long = 0
    For typeIndex As Long = 0 To nameIndex - 1
        Select Case tokens(typeIndex)
        Case "const"
            isConstLocal = -1
        Case "volatile", "restrict", "__restrict", "__restrict__", _
             "static", "auto", "register"
            Continue For
        Case Else
            If localArrayTypeName <> "" Then
                localArrayTypeNameIsAmbiguous = -1
                Exit For
            End If
            localArrayTypeName = tokens(typeIndex)
        End Select
    Next
    If localArrayTypeNameIsAmbiguous = 0 AndAlso _
       localArrayTypeName <> "" Then
        localArrayTypedefAliasIndex = _
            CBodyArrayTypeAliasIndexInContext( _
                translation, localArrayTypeName)
    End If
    If localArrayTypedefAliasIndex >= 0 Then
        With translation.body.aliases(localArrayTypedefAliasIndex)
            If .arrayCount < 1 OrElse _
               .arrayCount > MAX_SIMPLE_ARRAY_COUNT Then Return 0
            If .isConst <> 0 Then isConstLocal = -1
            If openingBracket >= 0 Then
                If isSymbolicArrayBound <> 0 OrElse isDynamicLocalArray <> 0 OrElse _
                   arrayRank <= 0 OrElse arrayRank >= MAX_GENERIC_ARRAY_RANK OrElse _
                   arrayCount <= 0 OrElse _
                   arrayCount > MAX_SIMPLE_ARRAY_COUNT \ .arrayCount Then Return 0
                Dim priorArrayRank As Long = arrayRank
                ReDim Preserve arrayDimensionBounds(0 To priorArrayRank)
                ReDim Preserve arrayDimensionCounts(0 To priorArrayRank)
                arrayDimensionBounds(priorArrayRank) = Trim(Str(.arrayCount)) & "ULL"
                arrayDimensionCounts(priorArrayRank) = .arrayCount
                arrayDimensions &= "," & arrayDimensionBounds(priorArrayRank)
                arrayCount *= .arrayCount
                arrayRank = priorArrayRank + 1
            Else
                arrayCount = .arrayCount
                arrayRank = 1
                arrayBound = Trim(Str(.arrayCount)) & "ULL"
                arrayDimensions = arrayBound
                ReDim arrayDimensionBounds(0 To 0)
                ReDim arrayDimensionCounts(0 To 0)
                arrayDimensionBounds(0) = arrayBound
                arrayDimensionCounts(0) = .arrayCount
            End If
        End With
    End If
    If nameIndex <= 0 OrElse IsIdentifierToken(tokens(nameIndex)) = 0 OrElse _
       IsTypeOrQualifierTokenInContext(translation, tokens(nameIndex)) <> 0 Then Return 0
    For i As Long = 0 To nameIndex - 1
        If tokens(i) = "," OrElse tokens(i) = "extern" Then Return 0
    Next
    Dim resolvedVariableType As C2fbResolvedTypeModel
    If localArrayTypedefAliasIndex >= 0 Then
        With translation.body.aliases(localArrayTypedefAliasIndex)
            resolvedVariableType.status = C2FB_TYPE_RESOLUTION_RESOLVED
            resolvedVariableType.freeBasicType = .arrayElementType
            resolvedVariableType.pointerCount = 0
            resolvedVariableType.isConst = CInt( _
                .isConst <> 0 OrElse isConstLocal <> 0) * -1
        End With
    ElseIf normalizedRawCallbackArray <> 0 Then
        Dim callbackArrayElementType As String
        For typeIndex As Long = 0 To nameIndex - 1
            Select Case tokens(typeIndex)
            Case "static", "const", "volatile", "restrict", _
                 "__restrict", "__restrict__"
                Continue For
            Case Else
                If callbackArrayElementType <> "" Then Return 0
                callbackArrayElementType = tokens(typeIndex)
            End Select
        Next
        If callbackArrayElementType = "" OrElse _
           IsCBodyCallbackTypeInContext( _
               translation, callbackArrayElementType) = 0 Then Return 0
        resolvedVariableType.status = C2FB_TYPE_RESOLUTION_RESOLVED
        resolvedVariableType.freeBasicType = callbackArrayElementType
        resolvedVariableType.pointerCount = 0
        resolvedVariableType.isConst = CInt(isConstLocal <> 0) * -1
    Else
        ResolveC2fbTypeModel( _
            translation, catalog, tokens(), 0, nameIndex - 1, _
            resolvedVariableType)
    End If
    If resolvedVariableType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0
    Dim variableType As String = resolvedVariableType.freeBasicType
    Dim pointerCount As Long = resolvedVariableType.pointerCount
    Dim isConst As Long = resolvedVariableType.isConst
    If resolvedVariableType.volatileMask <> 0 AndAlso arrayRank > 1 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-volatile-array", _
            "volatile multidimensional local arrays are not supported")
        Return 0
    End If
    Dim sourceRecordType As String
    For typeIndex As Long = nameIndex - 1 To 0 Step -1
        If IsIdentifierToken(tokens(typeIndex)) = 0 Then Continue For
        Dim sourceRecordKind As C2fbRecordKind = _
            CBodySourceRecordKindInContext(translation, tokens(typeIndex))
        If sourceRecordKind = C2FB_RECORD_STRUCT OrElse _
           sourceRecordKind = C2FB_RECORD_UNION Then
            sourceRecordType = tokens(typeIndex)
            Exit For
        End If
    Next
    If isStaticLocal <> 0 AndAlso isConstLocal <> 0 AndAlso _
       arrayRank > 1 AndAlso pointerCount = 0 Then
        isConst = -1
        If Left(variableType, Len("Const ")) <> "Const " Then _
            variableType = "Const " & variableType
    End If
    If variableType = "void" Then Return 0
    Dim isRecordArray As Long = 0
    Dim isRecordLocal As Long = 0
    Dim variableRecord As String = CBodyRecordName( _
        translation, catalog, variableType)
    ' An explicit map is the caller's storage assertion; its FreeBASIC type
    ' can be supplied by an include outside the indexed source directory.
    Dim hasExplicitSourceRecordTypeMap As Long = CInt( _
        GenericTypeOverrideInPolicy( _
            translation.genericC.policy, sourceRecordType) <> "")
    If sourceRecordType <> "" AndAlso pointerCount = 0 AndAlso _
       variableRecord = "" AndAlso hasExplicitSourceRecordTypeMap = 0 Then
        RecordSimpleBodyFailure( _
            context, "incomplete-local-record-layout", _
            "C record has no complete FreeBASIC storage layout: " & _
            sourceRecordType)
        Return 0
    End If
    ' Generated aliases can exist without a usable layout. For SQLite's
    ' stricter size-parity policy, also allow a complete catalog Type when
    ' the C record is not on the fixed-layout whitelist.
    If sourceRecordType <> "" AndAlso pointerCount = 0 AndAlso _
       variableRecord <> "" AndAlso hasExplicitSourceRecordTypeMap = 0 AndAlso _
       CBodyRecordSizeIsKnown( _
           translation, catalog, variableRecord) = 0 AndAlso _
       FbBodyRecordHasFieldModel(catalog, variableType) = 0 Then
        RecordSimpleBodyFailure( _
            context, "incomplete-local-record-layout", _
            "C record has no complete FreeBASIC storage layout: " & _
            sourceRecordType)
        Return 0
    End If
    ' Local C arrays use contiguous storage. Keep the source extents in the
    ' body symbol so multidimensional record indexing can flatten to the same
    ' element order without changing record layout.
    If isSymbolicArrayBound <> 0 AndAlso _
       (isStaticLocal <> 0 OrElse _
        (variableRecord <> "" AndAlso pointerCount = 0)) Then Return 0
    If variableRecord <> "" AndAlso pointerCount = 0 AndAlso _
       openingBracket < 0 AndAlso localArrayTypedefAliasIndex < 0 AndAlso _
       CBodyRecordSizeIsKnown( _
           translation, catalog, variableRecord) <> 0 Then
        isRecordLocal = -1
    ElseIf variableRecord <> "" AndAlso _
       (openingBracket >= 0 OrElse localArrayTypedefAliasIndex >= 0) AndAlso _
       pointerCount = 0 Then
        If arrayCount = 0 OrElse _
           (CBodyRecordSizeIsKnown(translation, catalog, variableRecord) = 0 AndAlso _
            FbBodyRecordHasFieldModel(catalog, variableType) = 0) Then Return 0
        isRecordArray = -1
    ElseIf localArrayTypedefAliasIndex < 0 AndAlso _
       C2fbTypeRecognitionStatusInContext( _
           translation, catalog, tokens(), 0, nameIndex - 1) <> _
           C2FB_TYPE_RESOLUTION_RESOLVED AndAlso _
           pointerCount = 0 AndAlso _
           IsCBodyCallbackTypeInContext(translation, variableType) = 0 Then
        If isStaticLocal = 0 OrElse isConstLocal = 0 OrElse _
           openingBracket < 0 OrElse arrayCount = 0 Then Return 0
        RecordSimpleBodyFailure( _
            context, "unsupported-local-aggregate-declaration", _
            "unsupported local aggregate declaration: " & Left(statementText, 160))
        Return 0
    End If
    If alignmentValue > 1 AndAlso _
       (arrayRank <> 1 OrElse isStaticLocal <> 0 OrElse _
        equalsPosition <> 0) Then
        RecordSimpleBodyFailure( _
            context, "unsupported-aligned-local-object", _
            "explicit alignment is supported only for automatic one-dimensional arrays without initializers: " & _
            Left(statementText, 160))
        Return 0
    End If
    If alignmentValue > 1 AndAlso isDynamicLocalArray <> 0 AndAlso _
       arrayCount <= 0 Then
        If dynamicBoundExpression = "" OrElse _
           EvaluateSimpleArrayBound( _
               dynamicBoundExpression, arrayCount, _
               MAX_GENERIC_ARRAY_COUNT) = 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-aligned-local-object", _
                "aligned local array bound must be a bounded constant: " & _
                Left(statementText, 160))
            Return 0
        End If
    End If
    If alignmentValue > 1 AndAlso arrayCount <= 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-aligned-local-object", _
            "aligned local array must have a positive fixed extent: " & _
            Left(statementText, 160))
        Return 0
    End If
    ' Opaque C pointers use Any Ptr in the port ABI as well as in local
    ' storage. If the body later dereferences an unmapped record, the
    ' expression parser still rejects that field access; the declaration
    ' itself does not need to be rejected just because its pointee is
    ' intentionally opaque (for example sqlite3_mutex*).
    Dim isTopLevelPointerConst As Long = 0
    If openingBracket >= 0 AndAlso pointerCount > 0 Then
        Dim finalPointerToken As Long = -1
        For tokenIndex As Long = 0 To nameIndex - 1
            If tokens(tokenIndex) = "*" Then finalPointerToken = tokenIndex
        Next
        For tokenIndex As Long = finalPointerToken + 1 To nameIndex - 1
            If tokens(tokenIndex) = "const" Then isTopLevelPointerConst = -1
        Next
    End If
    Dim staticPointerInitializerText As String
    If equalsPosition > 0 Then _
        staticPointerInitializerText = Trim(Mid(statementText, equalsPosition + 1))
    Dim staticPointerElementType As String = SimplePointeeType(variableType)
    Dim isStaticPointerArray As Long = CInt( _
        isStaticLocal <> 0 AndAlso openingBracket >= 0 AndAlso _
        (variableType = "Const ZString Ptr" OrElse _
         (pointerCount <> 0 AndAlso equalsPosition = 0) OrElse _
         (pointerCount = 1 AndAlso InStr( _
             staticPointerInitializerText, Chr(34)) <> 0 AndAlso _
          (staticPointerElementType = "Byte" OrElse _
           staticPointerElementType = "UByte" OrElse _
           staticPointerElementType = "c2fb_c_char" OrElse _
           staticPointerElementType = "c2fb_c_uchar")) OrElse _
         IsSimpleNullPointerInitializer(staticPointerInitializerText) <> 0))
    Dim isStaticCallbackScalar As Long = CInt( _
        isStaticLocal <> 0 AndAlso openingBracket < 0 AndAlso _
        localArrayTypedefAliasIndex < 0 AndAlso _
        (IsCBodyCallbackTypeInContext(translation, variableType) <> 0 OrElse _
         callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED))
    If isStaticLocal <> 0 AndAlso isRecordLocal <> 0 AndAlso _
       equalsPosition > 0 Then
        Dim recordInitializer As String = _
            Trim(Mid(statementText, equalsPosition + 1))
        Dim recordKind As C2fbRecordKind = _
            CBodySourceRecordKindInContext(translation, variableRecord)
        If Left(recordInitializer, 1) <> "{" OrElse _
           (recordKind <> C2FB_RECORD_STRUCT AndAlso _
            recordKind <> C2FB_RECORD_UNION AndAlso _
            variableRecord <> "FuncDef.u") Then
            RecordSimpleBodyFailure( _
                context, "unsupported-static-record-initializer", _
                "unsupported static record initializer: " & _
                Left(statementText, 160))
            Return 0
        End If
    End If
    If isStaticLocal <> 0 AndAlso pointerCount <> 0 AndAlso _
       openingBracket >= 0 AndAlso _
       isStaticPointerArray = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-static-local", _
            "unsupported static local: " & Left(statementText, 160))
        Return 0
    End If
    If isStaticCallbackScalar <> 0 AndAlso equalsPosition > 0 AndAlso _
       IsSupportedSimpleStaticCallbackInitializer( _
           translation, Trim(Mid(statementText, equalsPosition + 1)), _
           parameterNames(), symbolCount, callableNames(), callableCount) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-static-callback-initializer", _
            "unsupported static callback initializer: " & Left(statementText, 160))
        Return 0
    End If
    If isStaticLocal <> 0 AndAlso pointerCount <> 0 AndAlso _
       openingBracket < 0 AndAlso isStaticCallbackScalar = 0 AndAlso _
       equalsPosition > 0 AndAlso _
       IsSupportedSimpleStaticPointerInitializer( _
           translation, Trim(Mid(statementText, equalsPosition + 1)), _
           parameterNames(), symbolCount, variableType) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-static-local-initializer", _
            "unsupported static pointer initializer: " & Left(statementText, 160))
        Return 0
    End If
    Dim isStaticScalar As Long = CInt( _
        isStaticLocal <> 0 AndAlso openingBracket < 0 AndAlso _
        localArrayTypedefAliasIndex < 0)
    Dim variableName As String = tokens(nameIndex)
    Dim isCBoolLocal As Long = 0
    ' Normalize only scalar _Bool storage. A pointer-to-_Bool initializer must
    ' retain the pointer value instead of converting it to 0 or 1.
    If pointerCount = 0 Then
        For booleanTokenIndex As Long = 0 To nameIndex - 1
            If tokens(booleanTokenIndex) = "_Bool" OrElse _
               tokens(booleanTokenIndex) = "bool" Then
                isCBoolLocal = -1
                Exit For
            End If
        Next
    End If
    Dim scopeStart As Long = context.scopeSymbols(context.scopeDepth - 1)
    For i As Long = scopeStart To symbolCount - 1
        If parameterNames(i) = variableName Then Return 0
    Next
    If context.localSerial >= MAX_SIMPLE_VARIABLES Then Return 0
    If localCount >= MAX_SIMPLE_VARIABLES OrElse symbolCount >= MAX_SIMPLE_VARIABLES Then Return 0

    Dim initializer As String = ""
    Dim initializerPrelude As String
    Dim initializerSymbolCount As Long = symbolCount
    Dim initializerHasSelfName As Long = 0
    If equalsPosition > 0 AndAlso openingBracket < 0 AndAlso _
       localArrayTypedefAliasIndex < 0 Then
        ' C makes the declared name visible inside its initializer. Expose a
        ' temporary typed alias so unevaluated forms such as sizeof(*p) parse.
        parameterNames(symbolCount) = variableName
        parameterAliases(symbolCount) = "local" & Trim(Str(context.localSerial))
        parameterTypes(symbolCount) = variableType
        symbolCount += 1
        initializerHasSelfName = -1
    End If
    If isStaticScalar <> 0 AndAlso equalsPosition = 0 AndAlso _
       isRecordLocal = 0 Then initializer = "0"
    If equalsPosition > 0 AndAlso arrayCount = 0 Then
        initializer = Trim(Mid(statementText, equalsPosition + 1))
        If Len(initializer) = 0 Then
            If initializerHasSelfName <> 0 Then _
                symbolCount = initializerSymbolCount
            Return 0
        End If
        Dim translatedInitializer As String
        If isRecordLocal <> 0 AndAlso Left(initializer, 1) = "{" Then
            If TranslateSimpleRecordInitializer(translation, catalog,  _
                initializer, variableType, translatedInitializer, context, _
                callableNames(), callableCount, parameterNames(), _
                parameterAliases(), parameterTypes(), symbolCount, _
                CInt(isStaticLocal <> 0)) = 0 Then
                If initializerHasSelfName <> 0 Then _
                    symbolCount = initializerSymbolCount
                Return 0
            End If
            If isStaticLocal <> 0 Then _
                NormalizeGenericStaticInitializerValue(translatedInitializer)
        ElseIf isStaticScalar <> 0 Then
            Dim hasBoolean As Long
            Dim hasFunctionCall As Long
            Dim requiresFloatConstant As Long = CInt( _
                SimpleArithmeticKind(catalog, variableType) > 4)
            If TranslateSimpleExpression(translation, catalog, _
                                         initializer, translatedInitializer, hasBoolean, hasFunctionCall, _
                                         callableNames(), callableCount, parameterNames(), parameterAliases(), _
                                         parameterTypes(), symbolCount, variableType, 0, _
                                         requiresFloatConstant, isCBoolLocal) = 0 OrElse _
               hasFunctionCall <> 0 Then
                If initializerHasSelfName <> 0 Then _
                    symbolCount = initializerSymbolCount
                Return 0
            End If
            NormalizeGenericStaticInitializerValue(translatedInitializer)
        Else
            If TranslateSequencedExpression(translation, catalog, _
                                            initializer, translatedInitializer, initializerPrelude, context, _
                                            callableNames(), callableCount, parameterNames(), parameterAliases(), _
                                            parameterTypes(), symbolCount, variableType, isCBoolLocal) = 0 Then
                If initializerHasSelfName <> 0 Then _
                    symbolCount = initializerSymbolCount
                Return 0
            End If
        End If
        If initializerHasSelfName <> 0 Then _
            symbolCount = initializerSymbolCount
        initializer = translatedInitializer
    End If

    Dim localSizeofBytes As Long
    Dim localHasKnownSize As Long = 0
    Dim localSourceType As String
    For typeTokenIndex As Long = 0 To nameIndex - 1
        Select Case tokens(typeTokenIndex)
        Case "auto", "extern", "register", "static", "typedef"
            Continue For
        End Select
        If localSourceType <> "" Then localSourceType &= " "
        localSourceType &= tokens(typeTokenIndex)
    Next
    Dim localElementBytes As Long
    If localSourceType <> "" AndAlso _
       GenericArrayBoundTypeSizeInContext( _
           translation, localSourceType, localElementBytes) <> 0 Then
        Dim localObjectCount As Long = 1
        If arrayRank > 0 Then
            If arrayCount <= 0 OrElse _
               (isDynamicLocalArray <> 0 AndAlso alignmentValue <= 1) Then
                localObjectCount = 0
            Else
                localObjectCount = arrayCount
            End If
        End If
        If localObjectCount > 0 AndAlso localElementBytes > 0 AndAlso _
           localObjectCount <= MAX_GENERIC_ARRAY_COUNT \ localElementBytes Then
            localSizeofBytes = localObjectCount * localElementBytes
            localHasKnownSize = -1
        End If
    End If

    If alignmentValue > 1 AndAlso _
       (localHasKnownSize = 0 OrElse _
        localSizeofBytes > MAX_GENERIC_ARRAY_COUNT - alignmentValue + 1) Then
        RecordSimpleBodyFailure( _
            context, "unsupported-aligned-local-object", _
            "aligned local array has no bounded element size: " & _
            Left(statementText, 160))
        Return 0
    End If

    locals(localCount).name = variableName
    locals(localCount).typeName = variableType
    locals(localCount).isConst = isConst
    locals(localCount).pointerCount = pointerCount
    locals(localCount).volatileMask = resolvedVariableType.volatileMask
    locals(localCount).sizeofBytes = localSizeofBytes
    locals(localCount).hasKnownSize = localHasKnownSize
    locals(localCount).isIntegerConstant = 0
    locals(localCount).integerValue = 0
    localCount += 1
    parameterNames(symbolCount) = variableName
    parameterAliases(symbolCount) = "local" & Trim(Str(context.localSerial))
    Dim volatileLocalPointerCount As Long = pointerCount
    If resolvedVariableType.volatileMask <> 0 AndAlso _
       (arrayCount > 0 OrElse isSymbolicArrayBound <> 0) Then _
        volatileLocalPointerCount += 1
    RegisterSimpleBodyVolatileLocal( _
        context, parameterAliases(symbolCount), volatileLocalPointerCount, _
        resolvedVariableType.volatileMask)
    context.localSerial += 1
    parameterTypes(symbolCount) = variableType
    If isStaticPointerArray <> 0 AndAlso _
       isTopLevelPointerConst <> 0 Then _
        context.readOnlyAliases &= "|" & parameterAliases(symbolCount) & "|"
    If arrayCount > 0 OrElse isSymbolicArrayBound <> 0 Then
        Dim localArrayMetadataBound As String = arrayBound
        If alignmentValue > 1 Then _
            localArrayMetadataBound = Trim(Str(arrayCount)) & "ULL"
        parameterTypes(symbolCount) &= "[]" & localArrayMetadataBound & _
            "|" & arrayDimensions
        If alignmentValue > 1 Then _
            parameterTypes(symbolCount) &= "|aligned:" & Trim(Str(arrayCount))
    End If
    ' Const scalar and array storage is immutable. Pointer pointee qualifiers are
    ' carried by variableType; a trailing top-level pointer const does not
    ' make the pointed-to page bytes read-only.
    If isConst <> 0 AndAlso pointerCount = 0 Then _
        context.readOnlyAliases &= "|" & parameterAliases(symbolCount) & "|"
    symbolCount += 1
    ' Hoist storage, not initialization. Scalar/pointer locals have no BASIC
    ' destructor; C block names stay distinct even when a goto crosses a block.
    If isStaticScalar <> 0 Then
        ' Static local storage has process lifetime. Leave a record without
        ' an initializer here so FreeBASIC zero-fills its fields.
        context.declarations &= "    Static " & parameterAliases(symbolCount - 1) & _
            " As " & variableType
        If initializer <> "" Then context.declarations &= " = " & initializer
        context.declarations &= Chr(10)
        outputText = "' C static scalar storage"
        Return -1
    End If
    If arrayCount > 0 OrElse isSymbolicArrayBound <> 0 Then
        Dim arrayName As String = parameterAliases(symbolCount - 1)
        If isDynamicLocalArray <> 0 Then
            ' FreeBASIC allocates dynamic arrays on the heap. ReDim at the C
            ' declaration point preserves repeated block-entry bounds and
            ' zero-initializes omitted elements before C initializer writes.
            Dim alignedStorageName As String
            If alignmentValue > 1 Then
                alignedStorageName = "c2fb_local_alignment_storage_" & _
                    Trim(Str(context.localSerial - 1))
                context.declarations &= "    Dim " & alignedStorageName & _
                    "(Any) As UByte" & Chr(10)
                context.declarations &= "    Dim " & arrayName & " As " & _
                    variableType & " Ptr" & Chr(10)
            Else
                context.declarations &= "    Dim " & arrayName & "(Any) As " & _
                    variableType & Chr(10)
            End If
            If dynamicBoundPrelude <> "" Then _
                outputText = RTrim(dynamicBoundPrelude, Any Chr(10)) & Chr(10)
            If dynamicBoundExpression <> "" Then _
                outputText &= dynamicBoundName & " = " & _
                    dynamicBoundExpression & Chr(10)
            outputText &= _
                "' C local array bounds must fit FreeBASIC's signed array range" & Chr(10) & _
                "If " & dynamicBoundName & " <= 0 OrElse " & _
                dynamicBoundName & " > " & _
                Trim(Str(MAX_GENERIC_ARRAY_COUNT)) & " Then Error 5" & Chr(10)
            If alignmentValue > 1 Then
                outputText &= "ReDim " & alignedStorageName & "(0 To " & _
                    Trim(Str(localSizeofBytes + alignmentValue - 2)) & _
                    ") As UByte" & Chr(10)
                Dim alignmentText As String = Trim(Str(alignmentValue))
                outputText &= arrayName & " = CPtr(" & variableType & " Ptr, " & _
                    "((Cast(c2fb_size_t, @" & alignedStorageName & "(0)) + " & _
                    alignmentText & " - 1) \ " & alignmentText & ") * " & _
                    alignmentText & ")"
            Else
                outputText &= "ReDim " & arrayName & "(0 To " & dynamicBoundName & _
                    " - 1) As " & variableType
            End If
            If equalsPosition = 0 Then Return -1
            If arrayCount < 1 OrElse _
               arrayCount > MAX_DYNAMIC_ARRAY_INITIALIZER_COUNT Then Return 0
        ElseIf isStaticLocal <> 0 Then
            If equalsPosition = 0 Then
                ' C static arrays without an initializer have zero-filled
                ' storage for the lifetime of the process.
                context.declarations &= "    Static " & arrayName & "(0 To " & _
                    Trim(Str(arrayCount - 1)) & ") As " & variableType & Chr(10)
                outputText = "' C static array storage"
                Return -1
            End If
            Dim initializerValues As String = staticStringValues
            If staticStringInitializer = 0 Then
                Dim initializerText As String = Trim(Mid(statementText, equalsPosition + 1))
                If Left(initializerText, 1) <> "{" OrElse Right(initializerText, 1) <> "}" Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-static-array-initializer", _
                        "unsupported static array initializer: " & Left(statementText, 160))
                    Return 0
                End If
                Dim values() As String
                Dim valueCount As Long = 0
                If arrayRank > 1 Then
                    ReDim values(0 To arrayCount - 1)
                    If FlattenSimpleCArrayInitializer( _
                        initializerText, arrayDimensionCounts(), arrayRank, _
                        0, values(), valueCount, arrayCount, _
                        isRecordArray) = 0 OrElse _
                       valueCount <> arrayCount Then
                        RecordSimpleBodyFailure( _
                            context, "unsupported-static-array-initializer", _
                            "unsupported multidimensional static array initializer: " & _
                            Left(statementText, 160))
                        Return 0
                    End If
                Else
                    initializerText = Trim(Mid(initializerText, 2, Len(initializerText) - 2))
                    If Right(initializerText, 1) = "," Then _
                        initializerText = RTrim(Left(initializerText, Len(initializerText) - 1))
                    If SplitSimpleCList( _
                        initializerText, values(), valueCount) = 0 OrElse _
                       valueCount > arrayCount Then
                        RecordSimpleBodyFailure( _
                            context, "unsupported-static-array-initializer", _
                            "unsupported static array initializer: " & Left(statementText, 160))
                        Return 0
                    End If
                End If
                If arrayRank = 1 Then
                    Dim hasArrayDesignator As Long = 0
                    For i As Long = 0 To valueCount - 1
                        If Left(Trim(values(i)), 1) = "[" Then
                            hasArrayDesignator = -1
                            Exit For
                        End If
                    Next
                    If hasArrayDesignator = 0 AndAlso _
                       InStr(initializerText, "[") <> 0 Then
                        RecordSimpleBodyFailure( _
                            context, "unrecognized-local-array-designator", _
                            "local array designator was not split into elements: " & _
                            Left(initializerText, 160))
                        Return 0
                    End If
                    If hasArrayDesignator <> 0 Then
                        Dim sourceValues() As String
                        Dim sourceValueCount As Long = valueCount
                        If sourceValueCount > 0 Then
                            ReDim sourceValues(0 To sourceValueCount - 1)
                            For i As Long = 0 To sourceValueCount - 1
                                sourceValues(i) = values(i)
                            Next
                        End If
                        ReDim values(0 To arrayCount - 1)
                        Dim initializedElements() As Long
                        ReDim initializedElements(0 To arrayCount - 1)
                        Dim recordFieldInitializers() As String
                        ReDim recordFieldInitializers(0 To arrayCount - 1)
                        Dim hasRecordFieldDesignator As Long = 0
                        Dim nextElementIndex As Long = 0
                        For sourceIndex As Long = 0 To sourceValueCount - 1
                            Dim currentElementIndex As Long = nextElementIndex
                            Dim elementValue As String = Trim(sourceValues(sourceIndex))
                            If Left(elementValue, 1) = "[" Then
                                Dim fieldName As String
                                Dim fieldInitializer As String
                                If ParseSimpleArrayRecordFieldDesignator( _
                                    translation, elementValue, _
                                    currentElementIndex, fieldName, _
                                    fieldInitializer) <> 0 Then
                                    If isRecordArray = 0 Then
                                        RecordSimpleBodyFailure( _
                                            context, _
                                            "unmapped-record-array-designator", _
                                            "record field designator has no mapped local array type: " & _
                                            variableType)
                                        Return 0
                                    End If
                                    If currentElementIndex < 0 OrElse _
                                       currentElementIndex >= arrayCount OrElse _
                                       initializedElements(currentElementIndex) = 1 Then
                                        RecordSimpleBodyFailure( _
                                            context, _
                                            "invalid-static-record-array-designator", _
                                            "out-of-range or conflicting record array designator: " & _
                                            Trim(Str(currentElementIndex)))
                                        Return 0
                                    End If
                                    If recordFieldInitializers(currentElementIndex) <> "" Then _
                                        recordFieldInitializers(currentElementIndex) &= ", "
                                    recordFieldInitializers(currentElementIndex) &= _
                                        "." & fieldName & " = " & fieldInitializer
                                    initializedElements(currentElementIndex) = 2
                                    hasRecordFieldDesignator = -1
                                    nextElementIndex = currentElementIndex + 1
                                    Continue For
                                End If
                                Dim designatedValue As String
                                If ParseSimpleArrayDesignator( _
                                    translation, elementValue, currentElementIndex, _
                                    designatedValue) = 0 Then
                                    RecordSimpleBodyFailure( _
                                        context, "unsupported-static-array-designator", _
                                        "unsupported static array designator: " & _
                                        Left(elementValue, 120))
                                    Return 0
                                End If
                                elementValue = designatedValue
                            ElseIf hasRecordFieldDesignator <> 0 Then
                                RecordSimpleBodyFailure( _
                                    context, _
                                    "unsupported-static-record-array-initializer-order", _
                                    "a record-field designator must be followed by another indexed designator")
                                Return 0
                            End If
                            If currentElementIndex < 0 OrElse _
                               currentElementIndex >= arrayCount OrElse _
                               initializedElements(currentElementIndex) <> 0 Then
                                RecordSimpleBodyFailure( _
                                    context, "invalid-static-array-designator", _
                                    "out-of-range or repeated static array index: " & _
                                    Trim(Str(currentElementIndex)))
                                Return 0
                            End If
                            values(currentElementIndex) = elementValue
                            initializedElements(currentElementIndex) = -1
                            nextElementIndex = currentElementIndex + 1
                        Next
                        For i As Long = 0 To arrayCount - 1
                            If initializedElements(i) = 0 Then
                                values(i) = ""
                            ElseIf initializedElements(i) = 2 Then
                                values(i) = "{" & recordFieldInitializers(i) & "}"
                            End If
                        Next
                        valueCount = arrayCount
                    End If
                End If
                For i As Long = 0 To valueCount - 1
                    Dim translatedValue As String
                    If Trim(values(i)) = "" Then
                        translatedValue = "Cast(" & variableType & ", 0)"
                    ElseIf isRecordArray <> 0 Then
                        If TranslateSimpleRecordInitializer(translation, catalog,  _
                            values(i), variableType, translatedValue, context, _
                            callableNames(), callableCount, parameterNames(), _
                            parameterAliases(), parameterTypes(), symbolCount, _
                            CInt(isStaticLocal <> 0)) = 0 Then
                            RecordSimpleBodyFailure( _
                                context, "unsupported-static-record-initializer", _
                                "unsupported static record initializer: " & Left(values(i), 160))
                            Return 0
                        End If
                    Else
                        Dim hasBoolean As Long
                        Dim hasCall As Long
                        Dim requiresFloatConstant As Long = CInt( _
                            SimpleArithmeticKind(catalog, variableType) > 4)
                        If TranslateSimpleExpression(translation, catalog, _
                                                     values(i), translatedValue, hasBoolean, hasCall, _
                                                     callableNames(), callableCount, parameterNames(), _
                                                     parameterAliases(), parameterTypes(), symbolCount, _
                                                     "", -1, requiresFloatConstant) = 0 OrElse _
                           hasCall <> 0 Then
                            RecordSimpleBodyFailure( _
                                context, "unsupported-static-array-element", _
                                "unsupported static array element: " & Left(values(i), 120))
                            Return 0
                        End If
                        NormalizeGenericStaticInitializerValue(translatedValue)
                        translatedValue = "Cast(" & variableType & ", " & translatedValue & ")"
                    End If
                    If initializerValues <> "" Then
                        If isRecordArray <> 0 Then
                            initializerValues &= ", _" & Chr(10) & "        "
                        Else
                            initializerValues &= ", "
                        End If
                    End If
                    initializerValues &= translatedValue
                Next
                For i As Long = valueCount To arrayCount - 1
                    If initializerValues <> "" Then
                        If isRecordArray <> 0 Then
                            initializerValues &= ", _" & Chr(10) & "        "
                        Else
                            initializerValues &= ", "
                        End If
                    End If
                    If isRecordArray <> 0 Then
                        Dim zeroRecord As String
                        If TranslateSimpleRecordInitializer(translation, catalog,  _
                            "{}", variableType, zeroRecord, context, callableNames(), _
                            callableCount, parameterNames(), parameterAliases(), _
                            parameterTypes(), symbolCount) = 0 Then Return 0
                        initializerValues &= zeroRecord
                    Else
                        initializerValues &= "Cast(" & variableType & ", 0)"
                    End If
                Next
            Else
                Dim initialValues() As String
                Dim initialValueCount As Long
                If SplitSimpleCList(initializerValues, initialValues(), initialValueCount) = 0 OrElse _
                   initialValueCount > arrayCount Then Return 0
                For i As Long = initialValueCount To arrayCount - 1
                    If initializerValues <> "" Then initializerValues &= ", "
                    initializerValues &= "0"
                Next
            End If
            If isRecordArray <> 0 Then
                context.declarations &= "    Static " & arrayName & "(0 To " & _
                    Trim(Str(arrayCount - 1)) & ") As " & variableType & _
                    " = { _" & Chr(10) & "        " & initializerValues & "}" & Chr(10)
            Else
                context.declarations &= "    Static " & arrayName & "(0 To " & _
                    Trim(Str(arrayCount - 1)) & ") As " & variableType & _
                    " = {" & initializerValues & "}" & Chr(10)
            End If
            outputText = "' C static array storage"
            Return -1
        End If
        If isDynamicLocalArray = 0 Then
            Dim arrayLastIndex As String = Trim(Str(arrayCount - 1))
            If isSymbolicArrayBound <> 0 Then _
                arrayLastIndex = "(" & arrayBound & ") - 1"
            If alignmentValue > 1 Then
                Dim alignedStorageName As String = _
                    "c2fb_local_alignment_storage_" & _
                    Trim(Str(context.localSerial - 1))
                Dim alignedStorageLastIndex As String = Trim(Str( _
                    localSizeofBytes + alignmentValue - 2))
                context.declarations &= "    Dim " & alignedStorageName & _
                    "(0 To " & alignedStorageLastIndex & ") As UByte" & Chr(10)
                context.declarations &= "    Dim " & arrayName & " As " & _
                    variableType & " Ptr" & Chr(10)
                Dim alignmentText As String = Trim(Str(alignmentValue))
                outputText = arrayName & " = CPtr(" & variableType & " Ptr, " & _
                    "((Cast(c2fb_size_t, @" & alignedStorageName & "(0)) + " & _
                    alignmentText & " - 1) \ " & alignmentText & ") * " & _
                    alignmentText & ")"
            Else
                context.declarations &= "    Dim " & arrayName & "(0 To " & _
                    arrayLastIndex & ") As " & variableType & Chr(10)
            End If
            If equalsPosition = 0 Then
                If alignmentValue <= 1 Then _
                    outputText = "' C automatic array storage"
                Return -1
            End If
        End If
        Dim initializerText As String = Trim(Mid(statementText, equalsPosition + 1))
        Dim values() As String
        Dim valueCount As Long
        If arrayRank > 1 Then
            If arrayCount < 1 OrElse _
               arrayCount > MAX_DYNAMIC_ARRAY_INITIALIZER_COUNT Then Return 0
            ReDim values(0 To arrayCount - 1)
            valueCount = 0
            If FlattenSimpleCArrayInitializer( _
                Trim(Mid(statementText, equalsPosition + 1)), _
                arrayDimensionCounts(), arrayRank, 0, values(), valueCount, _
                arrayCount, isRecordArray) = 0 OrElse _
               valueCount <> arrayCount Then Return 0
        ElseIf staticStringInitializer <> 0 Then
            If SplitSimpleCList( _
                staticStringValues, values(), valueCount) = 0 OrElse _
               valueCount > arrayCount Then Return 0
        Else
            If Left(initializerText, 1) <> "{" OrElse _
               Right(initializerText, 1) <> "}" Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-local-array-initializer-list", _
                    "unsupported local array initializer: " & _
                    Left(initializerText, 160))
                Return 0
            End If
            initializerText = Trim(Mid( _
                initializerText, 2, Len(initializerText) - 2))
            If Right(initializerText, 1) = "," Then _
                initializerText = RTrim(Left( _
                    initializerText, Len(initializerText) - 1))
            If SplitSimpleCList(initializerText, values(), valueCount) = 0 OrElse _
               (valueCount > arrayCount AndAlso isRecordArray = 0) Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-local-array-initializer-list", _
                    "unsupported local array initializer elements: " & _
                    Left(initializerText, 160))
                Return 0
            End If
        End If
        Dim localArrayHasDesignator As Long = 0
        If LowerSimpleArrayInitializerDesignators( _
            translation, context, values(), valueCount, arrayCount, _
            isRecordArray, localArrayHasDesignator) = 0 Then Return 0
        ' ERASE clears a fixed BASIC array without freeing it. Repeat the clear
        ' at the declaration site so omitted C initializer elements reset even
        ' when that declaration is reached again in a loop.
        If isDynamicLocalArray = 0 Then outputText = "Erase " & arrayName
        For i As Long = 0 To valueCount - 1
            If values(i) = "" Then Continue For
            ' C zero can initialize a whole record. ERASE above already clears
            ' every field, so do not assign a scalar to a BASIC record element.
            If isRecordArray <> 0 AndAlso isDynamicLocalArray = 0 AndAlso _
               SimpleZeroIntegerExpression(values(i)) <> 0 Then Continue For
            Dim converted As String
            Dim valuePrelude As String
            ' Brace lists need C field-order lowering; record expressions use
            ' ordinary sequencing so calls keep their C evaluation order.
            If isRecordArray <> 0 AndAlso _
               Left(Trim(values(i)), 1) = "{" Then
                If TranslateSimpleRecordInitializer( _
                    translation, catalog, values(i), variableType, _
                    converted, context, callableNames(), callableCount, _
                    parameterNames(), parameterAliases(), parameterTypes(), _
                    symbolCount) = 0 Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-local-record-array-initializer", _
                        "unsupported local record array initializer: " & _
                        Left(Trim(values(i)), 160))
                    Return 0
                End If
            ElseIf TranslateSequencedExpression(translation, catalog, _
                values(i), converted, valuePrelude, context, _
                callableNames(), callableCount, parameterNames(), _
                parameterAliases(), parameterTypes(), symbolCount, _
                variableType) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-local-array-initializer-element", _
                    "unsupported local array initializer element: " & _
                    Left(Trim(values(i)), 160))
                Return 0
            End If
            If valuePrelude <> "" Then outputText &= Chr(10) & RTrim(valuePrelude, Any Chr(10))
            outputText &= Chr(10) & arrayName & "(" & Trim(Str(i)) & ") = " & converted
        Next
        Return -1
    End If
    context.declarations &= "    Dim " & parameterAliases(symbolCount - 1) & " As " & variableType & Chr(10)
    If initializer <> "" Then
        outputText = initializerPrelude & parameterAliases(symbolCount - 1) & " = " & initializer
    Else
        outputText = "' C automatic storage declaration"
    End If
    Return -1
End Function

Private Function TranslateSingleDeclarationStatement( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, _
    ByRef outputText As String, _
    ByRef context As SimpleBodyContext, _
    locals() As SimpleLocalVariable, _
    ByRef localCount As Long, _
    callableNames() As String, _
    ByVal callableCount As Long, _
    parameterNames() As String, _
    parameterAliases() As String, _
    parameterTypes() As String, _
    ByRef symbolCount As Long, _
    ByVal alignmentValue As Long _
) As Long
    Dim declarationPrefix As String = statementText
    Dim initializerEquals As Long = FindSimpleAssignmentEquals(statementText)
    If initializerEquals > 0 Then
        declarationPrefix = Trim(Left(statementText, initializerEquals - 1))
    End If
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(declarationPrefix, tokens(), tokenCount)
    Return TranslateSingleDeclarationStatementWithTokens( _
        translation, catalog, statementText, tokens(), tokenCount, outputText, _
        context, locals(), localCount, callableNames(), callableCount, _
        parameterNames(), parameterAliases(), parameterTypes(), symbolCount, _
        alignmentValue)
End Function


' Remove GNU attributes whose effects need no separate FreeBASIC annotation.
' FreeBASIC permits pointer aliasing: its GCC backend disables strict-alias
' optimization, and its LLVM backend emits no type-based alias metadata. Layout
' and calling attributes remain in the declaration so unsupported cases fail
' safely.
Private Function StripSimpleNonsemanticAttributes( _
    ByVal statementText As String _
) As String
    Dim result As String
    Dim position As Long = 1
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    Const attributeName As String = "__attribute__"

    While position <= Len(statementText)
        Dim currentByte As Long = Asc(statementText, position)
        If quoteByte <> 0 Then
            result &= Chr(currentByte)
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
        ElseIf currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
            result &= Chr(currentByte)
            position += 1
        ElseIf Mid(statementText, position, 2) = "/*" Then
            Dim commentEnd As Long = InStr(position + 2, statementText, "*/")
            If commentEnd = 0 Then
                result &= Mid(statementText, position)
                Exit While
            End If
            result &= Mid(statementText, position, commentEnd + 2 - position)
            position = commentEnd + 2
        ElseIf Mid(statementText, position, 2) = "//" Then
            result &= Mid(statementText, position)
            Exit While
        ElseIf Mid(statementText, position, Len(attributeName)) = attributeName AndAlso _
               (position = 1 OrElse _
                IsIdentifierPart(Asc(statementText, position - 1)) = 0) Then
            Dim afterName As Long = position + Len(attributeName)
            If afterName > Len(statementText) OrElse _
               IsIdentifierPart(Asc(statementText, afterName)) = 0 Then
                SkipCSpaces(statementText, afterName)
                If afterName <= Len(statementText) AndAlso _
                   Asc(statementText, afterName) = Asc("(") Then
                    Dim attributeEnd As Long = afterName
                    If ScanSimpleExpressionGroup( _
                        statementText, attributeEnd, Asc("("), Asc(")")) <> 0 Then
                        Dim attributeContents As String
                        For attributePosition As Long = afterName + 1 To attributeEnd - 2
                            If IsSpaceByte(Asc(statementText, attributePosition)) = 0 Then _
                                attributeContents &= LCase(Mid( _
                                    statementText, attributePosition, 1))
                        Next
                        Select Case attributeContents
                        Case "(__unused__)", "(unused)", _
                             "(__maybe_unused__)", "(maybe_unused)", _
                             "(__may_alias__)", "(may_alias)", _
                             "(__nonstring__)", "(nonstring)", _
                             "(__unused__,__nonstring__)", _
                             "(__nonstring__,__unused__)"
                            position = attributeEnd
                            Continue While
                        End Select
                    End If
                End If
            End If
            result &= Chr(currentByte)
            position += 1
        Else
            result &= Chr(currentByte)
            position += 1
        End If
    Wend

    Return result
End Function


Private Function StripSimpleAlignmentSpecifiers( _
    ByVal statementText As String, _
    ByRef normalizedText As String, _
    ByRef alignmentValue As Long _
) As Long
    normalizedText = ""
    alignmentValue = 0
    Dim position As Long = 1
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0

    While position <= Len(statementText)
        Dim currentByte As Long = Asc(statementText, position)
        If quoteByte <> 0 Then
            normalizedText &= Chr(currentByte)
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
        ElseIf currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
            normalizedText &= Chr(currentByte)
            position += 1
        ElseIf Mid(statementText, position, 2) = "/*" Then
            Dim commentEnd As Long = InStr(position + 2, statementText, "*/")
            If commentEnd = 0 Then
                normalizedText &= Mid(statementText, position)
                Exit While
            End If
            normalizedText &= Mid(statementText, position, commentEnd + 2 - position)
            position = commentEnd + 2
        ElseIf Mid(statementText, position, 2) = "//" Then
            normalizedText &= Mid(statementText, position)
            Exit While
        ElseIf Mid(statementText, position, 8) = "_Alignas" OrElse _
               Mid(statementText, position, 7) = "alignas" Then
            Dim nameLength As Long = 7
            If Mid(statementText, position, 8) = "_Alignas" Then nameLength = 8
            Dim afterName As Long = position + nameLength
            If (position = 1 OrElse _
                IsIdentifierPart(Asc(statementText, position - 1)) = 0) AndAlso _
               (afterName > Len(statementText) OrElse _
                IsIdentifierPart(Asc(statementText, afterName)) = 0) Then
                SkipCSpaces(statementText, afterName)
                If afterName <= Len(statementText) AndAlso _
                   Asc(statementText, afterName) = Asc("(") Then
                    Dim alignmentEnd As Long = afterName
                    If ScanSimpleExpressionGroup( _
                        statementText, alignmentEnd, Asc("("), Asc(")")) = 0 Then _
                        Return 0
                    Dim alignmentExpression As String = Trim(Mid( _
                        statementText, afterName + 1, _
                        alignmentEnd - afterName - 2))
                    Dim requestedAlignment As Long
                    If EvaluateSimpleArrayBound( _
                        alignmentExpression, requestedAlignment, _
                        MAX_SIMPLE_ARRAY_COUNT, -1) = 0 Then Return 0
                    If requestedAlignment > alignmentValue Then _
                        alignmentValue = requestedAlignment
                    position = alignmentEnd
                ElseIf nameLength = 8 Then
                    Return 0
                Else
                    normalizedText &= Mid(statementText, position, nameLength)
                    position += nameLength
                End If
            Else
                normalizedText &= Chr(currentByte)
                position += 1
            End If
        Else
            normalizedText &= Chr(currentByte)
            position += 1
        End If
    Wend

    Return -1
End Function

Private Function TranslateSimpleDeclarationStatement( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, ByRef outputText As String, _
    ByRef context As SimpleBodyContext, locals() As SimpleLocalVariable, ByRef localCount As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, parameterTypes() As String, _
    ByRef symbolCount As Long _
) As Long
    statementText = StripSimpleNonsemanticAttributes(statementText)
    Dim alignmentValue As Long
    Dim alignmentStrippedText As String
    If StripSimpleAlignmentSpecifiers( _
        statementText, alignmentStrippedText, alignmentValue) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-local-alignment", _
            "unsupported local alignment specifier: " & _
            Left(statementText, 160))
        Return 0
    End If
    statementText = alignmentStrippedText
    ' Normalize an inline anonymous record before splitting its declarators so
    ' every object shares the same generated FreeBASIC record type.
    statementText = NormalizeCInlineRecordArrayDeclaration( _
        translation, catalog, context, statementText)
    Dim parts() As String
    Dim partCount As Long
    If SplitSimpleCList(statementText, parts(), partCount) = 0 Then Return 0

    If partCount = 1 Then
        Return TranslateSingleDeclarationStatement( _
            translation, catalog, Trim(parts(0)), outputText, context, _
            locals(), localCount, callableNames(), callableCount, _
            parameterNames(), parameterAliases(), parameterTypes(), symbolCount, _
            alignmentValue)
    End If

    Dim sourceTokens() As String
    Dim sourceTokenCount As Long
    TokenizeCDeclaration(statementText, sourceTokens(), sourceTokenCount)
    Dim sourceRanges() As C2fbTokenRangeModel
    Dim sourceRangeCount As Long = 0
    ' Use shared token ranges when they agree with the retained source parts.
    If sourceTokenCount > 0 AndAlso _
       SplitC2fbTokenList( _
           sourceTokens(), 0, sourceTokenCount - 1, _
           sourceRanges(), sourceRangeCount) <> 0 AndAlso _
       sourceRangeCount = partCount Then
        If sourceRangeCount = 1 Then
            Dim singleTokens() As String
            Dim singleTokenCount As Long
            If BuildC2fbDeclaratorPartTokens( _
                sourceTokens(), sourceRanges(), sourceRangeCount, 0, 0, _
                singleTokens(), singleTokenCount) <> 0 Then
                Return TranslateSingleDeclarationStatementWithTokens( _
                    translation, catalog, Trim(parts(0)), singleTokens(), _
                    singleTokenCount, outputText, context, locals(), localCount, _
                    callableNames(), callableCount, parameterNames(), _
                    parameterAliases(), parameterTypes(), symbolCount, _
                    alignmentValue)
            End If
        End If
        Dim firstTokens() As String
        Dim firstTokenCount As Long = 0
        If BuildC2fbDeclaratorPartTokens( _
            sourceTokens(), sourceRanges(), sourceRangeCount, 0, 0, _
            firstTokens(), firstTokenCount) <> 0 Then
            If firstTokenCount > 0 AndAlso _
               firstTokens(firstTokenCount - 1) = ";" Then _
                firstTokenCount -= 1
            Dim tokenAssignmentIndex As Long
            If firstTokenCount >= 2 AndAlso _
               FindC2fbTopLevelAssignmentToken( _
                   firstTokens(), 0, firstTokenCount - 1, _
                   tokenAssignmentIndex) <> 0 Then
                Dim typeDeclarationTokenCount As Long = firstTokenCount
                If tokenAssignmentIndex >= 0 Then _
                    typeDeclarationTokenCount = tokenAssignmentIndex
                Dim tokenNameIndex As Long = typeDeclarationTokenCount - 1
                For tokenIndex As Long = 0 To typeDeclarationTokenCount - 1
                    If firstTokens(tokenIndex) = "[" Then
                        tokenNameIndex = tokenIndex - 1
                        Exit For
                    End If
                Next
                Dim tokenTypeEnd As Long = tokenNameIndex - 1
                While tokenTypeEnd >= 0 AndAlso _
                      (firstTokens(tokenTypeEnd) = "*" OrElse _
                       IsQualifierToken(firstTokens(tokenTypeEnd)) <> 0)
                    tokenTypeEnd -= 1
                Wend

                If tokenTypeEnd >= 0 Then
                    Dim tokenBaseType As String
                    For tokenIndex As Long = 0 To tokenTypeEnd
                        If tokenIndex > 0 Then tokenBaseType &= " "
                        tokenBaseType &= firstTokens(tokenIndex)
                    Next
                    Dim tokenCommonTypeCount As Long = tokenTypeEnd + 1
                    Dim canBuildAllParts As Long = -1
                    For validationPartIndex As Long = 0 To partCount - 1
                        Dim validationTokens() As String
                        Dim validationTokenCount As Long
                        If BuildC2fbDeclaratorPartTokens( _
                            sourceTokens(), sourceRanges(), sourceRangeCount, _
                            validationPartIndex, tokenCommonTypeCount, _
                            validationTokens(), validationTokenCount) = 0 Then
                            canBuildAllParts = 0
                            Exit For
                        End If
                    Next

                    If canBuildAllParts <> 0 Then
                        outputText = ""
                        For tokenPartIndex As Long = 0 To partCount - 1
                            Dim tokenItemDeclaration As String = _
                                Trim(parts(tokenPartIndex))
                            If tokenPartIndex > 0 Then _
                                tokenItemDeclaration = _
                                    tokenBaseType & " " & tokenItemDeclaration
                            Dim itemTokens() As String
                            Dim itemTokenCount As Long
                            If BuildC2fbDeclaratorPartTokens( _
                                sourceTokens(), sourceRanges(), sourceRangeCount, _
                                tokenPartIndex, tokenCommonTypeCount, _
                                itemTokens(), itemTokenCount) = 0 Then _
                                ReportError("body declaration token split changed during lowering")
                            Dim converted As String
                            If TranslateSingleDeclarationStatementWithTokens( _
                                translation, catalog, tokenItemDeclaration, _
                                itemTokens(), itemTokenCount, converted, context, _
                                locals(), localCount, callableNames(), callableCount, _
                                parameterNames(), parameterAliases(), parameterTypes(), _
                                symbolCount, alignmentValue) = 0 Then Return 0
                            If tokenPartIndex > 0 Then outputText &= Chr(10)
                            outputText &= converted
                        Next
                        Return -1
                    End If
                End If
            End If
        End If
    End If

    Dim prefix As String = parts(0)
    Dim equalsPosition As Long = InStr(prefix, "=")
    If equalsPosition > 0 Then prefix = Trim(Left(prefix, equalsPosition - 1))
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(prefix, tokens(), tokenCount)
    If tokenCount < 2 Then Return 0
    Dim nameIndex As Long = tokenCount - 1
    For i As Long = 0 To tokenCount - 1
        If tokens(i) = "[" Then
            nameIndex = i - 1
            Exit For
        End If
    Next
    Dim typeEnd As Long = nameIndex - 1
    While typeEnd >= 0 AndAlso (tokens(typeEnd) = "*" OrElse IsQualifierToken(tokens(typeEnd)) <> 0)
        typeEnd -= 1
    Wend
    If typeEnd < 0 Then Return 0
    Dim baseType As String
    For i As Long = 0 To typeEnd
        If i > 0 Then baseType &= " "
        baseType &= tokens(i)
    Next
    outputText = ""
    For i As Long = 0 To partCount - 1
        Dim declaration As String = parts(i)
        If i > 0 Then declaration = baseType & " " & declaration
        Dim converted As String
        If TranslateSingleDeclarationStatement(translation, catalog, declaration, converted, context, locals(), localCount, _
                                              callableNames(), callableCount, parameterNames(), _
                                              parameterAliases(), parameterTypes(), symbolCount, _
                                              alignmentValue) = 0 Then Return 0
        If i > 0 Then outputText &= Chr(10)
        outputText &= converted
    Next
    Return -1
End Function

/' end of c2fb_body_declarations.bi '/
