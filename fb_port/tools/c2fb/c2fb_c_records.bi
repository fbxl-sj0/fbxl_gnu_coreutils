/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_c_records.bi

    Purpose:

        Bind C record member types to existing FreeBASIC layouts for body
        conversion.

    Responsibilities:

        - Read C record declarations from the shared declaration table.
        - Index source and FreeBASIC field names for bounded member lookup.
        - Retain scalar, pointer, array, and nested record member types.
        - Preserve supported C bitfield widths from their original expressions.
        - Give anonymous C records a stable path through their containing field.
        - Match existing BASIC record names through corresponding fields.
        - Generate private BASIC layouts for safe, complete source-local structs.
        - Prefer an exact C record tag before resolving typedef aliases.
        - Supply C member types when the port stores a pointer as Any Ptr.

    This file intentionally does NOT contain:

        - Guessing layouts for unions, packed records, bitfields, or incomplete types.
        - Claims that partial port layouts match C.
        - Preprocessor branch evaluation or C record memory offsets.
'/

' These catalogs belong to one serial input-file conversion. Source member
' declarations remain the authority for C types; BASIC fields supply spelling
' and storage syntax, including opaque pointer slots and fixed-array members.
Private Const C2FB_BITFIELD_SIGNEDNESS_UNKNOWN As Long = 0
Private Const C2FB_BITFIELD_SIGNEDNESS_SIGNED As Long = 1
Private Const C2FB_BITFIELD_SIGNEDNESS_UNSIGNED As Long = 2

Private Function CBodyRecordFieldIndex( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal ownerName As String, ByVal fieldName As String _
) As Long
    ' Prefer the exact C tag. A typedef may map the same name to a BASIC type,
    ' which is not necessarily the owner name retained by the C record parser.
    Dim key As String = ownerName & Chr(1) & fieldName
    Dim fieldIndex As Long = C2fbStringIndexMapLookup( _
        translation.body.recordFieldIndex, key)
    If fieldIndex >= 0 AndAlso _
       fieldIndex < translation.body.recordFieldCount Then Return fieldIndex

    ' C fields may use a typedef name while the record declaration uses a
    ' different struct tag. Try the resolved alias only after the exact tag.
    Dim pointerCount As Long
    Dim isConst As Long
    Dim resolvedOwner As String = LookupCBodyTypeAliasInContext( _
        translation, ownerName, pointerCount, isConst)
    If resolvedOwner <> "" AndAlso pointerCount = 0 Then ownerName = resolvedOwner
    key = ownerName & Chr(1) & fieldName
    fieldIndex = C2fbStringIndexMapLookup( _
        translation.body.recordFieldIndex, key)
    If fieldIndex >= 0 AndAlso _
       fieldIndex < translation.body.recordFieldCount Then Return fieldIndex
    Return -1
End Function

Private Function CBodyRecordTagAliasInContext( _
    ByRef translation As C2fbTranslationContext, ByVal aliasName As String _
) As String
    Dim recordTag As String = ""
    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               .isConditional <> 0 OrElse .isTypedef = 0 OrElse _
               .recordTag = "" OrElse .recordAlias <> aliasName Then Continue For
            If recordTag <> "" AndAlso recordTag <> .recordTag Then Return ""
            recordTag = .recordTag
        End With
    Next
    Return recordTag
End Function

Private Function CBodyRecordFieldIndexForMappedFbRecord( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal fbRecord As String, ByVal fieldName As String _
) As Long
    Dim matchedIndex As Long = -1
    Dim matchedOwner As String = ""
    For fieldIndex As Long = 0 To translation.body.recordFieldCount - 1
        With translation.body.recordFields(fieldIndex)
            If .name <> fieldName OrElse _
               MappedFbBodyRecord(translation, catalog, .ownerName) <> fbRecord Then _
                Continue For
            If matchedIndex >= 0 AndAlso matchedOwner <> .ownerName Then Return -1
            matchedIndex = fieldIndex
            matchedOwner = .ownerName
        End With
    Next
    Return matchedIndex
End Function

Private Function CBodyFreeBasicFieldIndexKey( _
    ByVal ownerName As String, ByVal fieldName As String _
) As String
    Return ownerName & Chr(1) & LCase(fieldName)
End Function

Private Sub IndexCBodyRecordField( _
    ByRef translation As C2fbTranslationContext, ByVal fieldIndex As Long _
)
    If fieldIndex < 0 OrElse _
       fieldIndex >= translation.body.recordFieldCount Then Exit Sub
    With translation.body.recordFields(fieldIndex)
        Dim sourceKey As String = .ownerName & Chr(1) & .name
        If C2fbStringIndexMapLookup( _
            translation.body.recordFieldIndex, sourceKey) < 0 Then
            If AddC2fbStringIndexMapEntry( _
                translation.body.recordFieldIndex, sourceKey, fieldIndex) = 0 Then _
                ReportError("C record field index exceeds the configured limit")
        End If

        If .freeBasicName <> "" Then
            Dim freeBasicKey As String = CBodyFreeBasicFieldIndexKey( _
                .ownerName, .freeBasicName)
            If C2fbStringIndexMapLookup( _
                translation.body.recordFreeBasicNameIndex, freeBasicKey) < 0 Then
                If AddC2fbStringIndexMapEntry( _
                    translation.body.recordFreeBasicNameIndex, freeBasicKey, _
                    fieldIndex) = 0 Then _
                    ReportError("FreeBASIC record field name index exceeds the configured limit")
            End If
        End If
    End With
End Sub

Private Sub RebuildCBodyRecordFieldIndexes( _
    ByRef translation As C2fbTranslationContext _
)
    ResetC2fbStringIndexMap(translation.body.recordFieldIndex)
    ResetC2fbStringIndexMap(translation.body.recordFreeBasicNameIndex)
    For fieldIndex As Long = 0 To translation.body.recordFieldCount - 1
        IndexCBodyRecordField(translation, fieldIndex)
    Next
End Sub

Private Function CBodyFreeBasicFieldNameInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal ownerName As String, ByVal sourceFieldName As String _
) As String
    Dim freeBasicName As String = sourceFieldName
    If C2fbFreeBasicFieldIdentifierNeedsEscape(freeBasicName) <> 0 Then _
        freeBasicName &= "_"
    Do
        Dim key As String = CBodyFreeBasicFieldIndexKey(ownerName, freeBasicName)
        If C2fbStringIndexMapLookup( _
            translation.body.recordFreeBasicNameIndex, key) < 0 Then Exit Do
        freeBasicName &= "_"
    Loop
    Return freeBasicName
End Function

Private Sub BindCBodyRecord( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByVal fbName As String, _
    ByVal isGenerated As Long = 0, _
    ByVal recordKind As C2fbRecordKind = C2FB_RECORD_KIND_NONE _
)
    If sourceName = "" OrElse fbName = "" Then Exit Sub
    For i As Long = 0 To translation.body.recordBindingCount - 1
        If translation.body.recordBindings(i).sourceName = sourceName Then Exit Sub
    Next
    If translation.body.recordBindingCount >= _
       MAX_C2FB_BODY_RECORD_BINDINGS Then _
        ReportError("record bindings exceed the configured limit")
    If translation.body.recordBindingCount > UBound(translation.body.recordBindings) Then _
        ReDim Preserve translation.body.recordBindings(0 To UBound(translation.body.recordBindings) * 2 + 1)
    translation.body.recordBindings(translation.body.recordBindingCount).sourceName = sourceName
    translation.body.recordBindings(translation.body.recordBindingCount).fbName = fbName
    translation.body.recordBindings(translation.body.recordBindingCount).recordKind = _
        recordKind
    translation.body.recordBindings(translation.body.recordBindingCount).isGenerated = _
        isGenerated
    translation.body.recordBindingCount += 1
End Sub

Private Function CBodyRecordHasMappedField( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal freeBasicRecordName As String, _
    ByVal sourceFieldIndex As Long _
) As Long
    If sourceFieldIndex < 0 OrElse _
       sourceFieldIndex >= translation.body.recordFieldCount Then Return 0
    With translation.body.recordFields(sourceFieldIndex)
        If LookupFbBodyField( _
            translation, catalog, freeBasicRecordName, .name, _
            sourceFieldIndex) >= 0 Then Return -1
        If .bitWidth < 0 Then Return 0
        Dim storageFieldName As String = _
            MappedFbBitFieldStorageField( _
                translation, freeBasicRecordName, .name)
        If storageFieldName = "" Then Return 0
        If LookupFbBodyField( _
            translation, catalog, freeBasicRecordName, storageFieldName) >= 0 Then _
            Return -1
    End With
    Return 0
End Function

Declare Sub RecordCBodyFieldWithTokens( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal ownerName As String, ByVal declaration As String, _
    tokens() As String, ByVal count As Long, ByRef commonType As String, _
    ByRef commonTypeTokenCount As Long, _
    ByVal part As Long, ByVal nestedType As String, _
    ByVal nestedTypeKind As C2fbRecordKind, _
    ByVal anonymousUnionGroup As Long _
)

Private Function LookupCBodyRecordBindingInContext( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As String
    For i As Long = 0 To translation.body.recordBindingCount - 1
        If translation.body.recordBindings(i).sourceName = sourceName Then _
            Return translation.body.recordBindings(i).fbName
    Next
    Return ""
End Function

Private Function LookupCBodyGeneratedRecordBindingInContext( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As String
    For i As Long = 0 To translation.body.recordBindingCount - 1
        With translation.body.recordBindings(i)
            If .isGenerated <> 0 AndAlso .sourceName = sourceName Then _
                Return .fbName
        End With
    Next
    Return ""
End Function

Private Function CBodyRecordName( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal fbType As String _
) As String
    fbType = ResolveFbBodyRecordOwner(catalog, fbType)
    ' The two flexible-list element types are standalone layouts in the port,
    ' even when a preprocessed source omits their enclosing member metadata.
    If translation.target.profile = C2FB_TARGET_SQLITE Then
        Select Case fbType
        Case "SqliteExprListItem": Return "ExprList_item"
        Case "SqliteIdListItem": Return "IdList_item"
        Case "SqliteSubroutineSignature": Return "SubrtnSig"
        End Select
    End If
    ' sqlite3 is a private connection record with the same name in C and in
    ' the port. Keep that exact owner so array fields such as aLimit retain
    ' their declared storage type in sizeof and member expressions.
    If translation.target.profile = C2FB_TARGET_SQLITE Then
        If fbType = "sqlite3" Then Return "sqlite3"
        If fbType = "SqlitePragmaEncodingName" Then Return "EncName"
    End If
    For i As Long = 0 To translation.body.recordBindingCount - 1
        If LCase(ResolveFbBodyRecordOwner(catalog, translation.body.recordBindings(i).fbName)) = LCase(fbType) Then _
            Return translation.body.recordBindings(i).sourceName
    Next
    ' Enum aliases often map to scalar FreeBASIC types such as Long. They do
    ' not describe record storage and must not claim that scalar's layout.
    Dim generatedRecordPrefix As String = _
        translation.genericC.policy.generatedNamePrefix
    If generatedRecordPrefix = "" Then generatedRecordPrefix = "c2fb_"
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               .recordKind = C2FB_RECORD_ENUM Then Continue For
            Dim sourceNames(0 To 1) As String
            sourceNames(0) = .recordTag
            sourceNames(1) = .recordAlias
            For sourceIndex As Long = 0 To 1
                Dim sourceName As String = sourceNames(sourceIndex)
                If sourceName = "" Then Continue For
                Dim generatedOwner As String = ResolveFbBodyRecordOwner( _
                    catalog, generatedRecordPrefix & sourceName)
                If LCase(generatedOwner) = LCase(fbType) Then _
                    Return sourceName
            Next
        End With
    Next
    ' A mapped nested C record may be declared in the current input while its
    ' FreeBASIC layout comes from another source unit. Recover the C tag from
    ' an explicit map or the generated c2fb_ name so later member accesses can
    ' still use the current unit's C field types.
    Dim generatedPrefix As String = _
        translation.genericC.policy.generatedNamePrefix
    If generatedPrefix = "" Then generatedPrefix = "c2fb_"
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               .recordKind = C2FB_RECORD_ENUM Then Continue For
            Dim sourceNames(0 To 1) As String
            sourceNames(0) = .recordTag
            sourceNames(1) = .recordAlias
            For sourceIndex As Long = 0 To 1
                Dim sourceName As String = sourceNames(sourceIndex)
                If sourceName = "" Then Continue For
                Dim mappedType As String = GenericTypeOverrideInPolicy( _
                    translation.genericC.policy, sourceName)
                If mappedType = "" Then mappedType = generatedPrefix & sourceName
                If LCase(ResolveFbBodyRecordOwner(catalog, mappedType)) = _
                   LCase(fbType) Then Return sourceName
            Next
        End With
    Next
    Return ""
End Function

Private Function CBodyRecordTag( _
    ByVal declaration As String, ByRef isRecord As Long, _
    ByRef recordKind As C2fbRecordKind _
) As String
    isRecord = 0
    Dim recordTag As String
    Dim isTypedef As Long
    Dim isPacked As Long
    recordKind = C2fbRecordKindFromPrefix( _
        declaration, recordTag, isTypedef, isPacked)
    If recordKind <> C2FB_RECORD_STRUCT AndAlso _
       recordKind <> C2FB_RECORD_UNION Then Return ""
    isRecord = -1
    Return recordTag
End Function

Private Sub RecordCBodyField( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal ownerName As String, ByVal declaration As String, _
    ByVal nestedType As String = "", _
    ByVal nestedTypeKind As C2fbRecordKind = C2FB_RECORD_KIND_NONE, _
    ByVal anonymousUnionGroup As Long = 0 _
)
    Dim parts() As String
    Dim partCount As Long
    If SplitSimpleCList(declaration, parts(), partCount) = 0 Then Exit Sub
    Dim commonType As String
    For part As Long = 0 To partCount - 1
        Dim text As String = parts(part)
        If part > 0 Then text = commonType & " " & text
        Dim tokens() As String
        Dim count As Long
        TokenizeCDeclaration(text, tokens(), count)
        Dim commonTypeTokenCount As Long = 0
        RecordCBodyFieldWithTokens( _
            translation, catalog, ownerName, text, tokens(), count, _
            commonType, commonTypeTokenCount, part, nestedType, nestedTypeKind, _
            anonymousUnionGroup)
    Next
End Sub

Private Sub RecordCBodyFieldWithTokens( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal ownerName As String, ByVal declaration As String, _
    tokens() As String, ByVal count As Long, ByRef commonType As String, _
    ByRef commonTypeTokenCount As Long, _
    ByVal part As Long, ByVal nestedType As String, _
    ByVal nestedTypeKind As C2fbRecordKind, _
    ByVal anonymousUnionGroup As Long _
)
    If count < 2 OrElse count >= MAX_TYPE_WORDS Then Exit Sub
    Dim anonymousEnumBody As String
    Dim anonymousEnumStart As Long
    Dim anonymousEnumEnd As Long
    Dim hasAnonymousEnumSyntax As Long = GenericFindAnonymousEnumBody( _
        declaration, anonymousEnumBody, anonymousEnumStart, anonymousEnumEnd)
    Dim hasAnonymousEnumType As Long = _
        GenericAnonymousEnumFieldTypeBody( _
            translation, declaration, anonymousEnumBody)
    If hasAnonymousEnumSyntax <> 0 AndAlso hasAnonymousEnumType = 0 Then _
        ReportC2fbRejected(translation, ownerName, _
            "unsupported-anonymous-enum-record-field", _
            Left(Trim(declaration), 160))
    Dim callbackResult As C2fbCallbackTypeResultModel
    If hasAnonymousEnumType <> 0 Then
        callbackResult.status = C2FB_CALLBACK_TYPE_NOT_CALLBACK
    Else
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, tokens(), 0, count - 1, _
            callbackResult, 0, C2FB_TYPE_MAPPING_BODY)
    End If
    If callbackResult.status = C2FB_CALLBACK_TYPE_UNSUPPORTED Then Exit Sub
    If callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED AndAlso _
       callbackResult.callbackName <> "" Then
        If translation.body.recordFieldCount >= _
           MAX_C2FB_BODY_RECORD_FIELDS Then _
            ReportError("C record fields exceed the configured limit")
        If translation.body.recordFieldCount > UBound(translation.body.recordFields) Then _
            ReDim Preserve translation.body.recordFields(0 To UBound(translation.body.recordFields) * 2 + 1)
        With translation.body.recordFields(translation.body.recordFieldCount)
            .ownerName = ownerName
            .name = callbackResult.callbackName
            .freeBasicName = callbackResult.callbackName
            .callbackType = callbackResult.freeBasicType
            .bitWidth = -1
        End With
        translation.body.recordFieldCount += 1
        IndexCBodyRecordField( _
            translation, translation.body.recordFieldCount - 1)
        Exit Sub
    End If
        Dim nameIndex As Long = count - 1
        Dim isArray As Long = 0
        Dim arrayBound As String
        Dim bitWidth As Long = -1
        For i As Long = 0 To count - 1
            If tokens(i) = "[" Then
                nameIndex = i - 1
                isArray = -1
                Dim openingBracket As Long = InStr(declaration, "[")
                If openingBracket > 0 Then
                    Dim closingBracket As Long = InStr(openingBracket + 1, declaration, "]")
                    If closingBracket > openingBracket + 1 AndAlso _
                       InStr(closingBracket + 1, declaration, "[") = 0 Then
                        ' Keep the original decimal token intact. The general
                        ' declaration tokenizer is for C types and splits
                        ' digits into punctuation-sized tokens.
                        arrayBound = Trim(Mid(declaration, openingBracket + 1, _
                            closingBracket - openingBracket - 1))
                    End If
                End If
                Exit For
            ElseIf tokens(i) = ":" Then
                nameIndex = i - 1
                ' The declaration tokenizer splits decimal digits into
                ' individual tokens. Evaluate the original width expression
                ' so widths such as 13 do not silently become 1.
                bitWidth = 65
                Dim colonPosition As Long = InStr(declaration, ":")
                Dim parsedBitWidth As Long
                If colonPosition > 0 AndAlso EvaluateSimpleArrayBound( _
                    Trim(Mid(declaration, colonPosition + 1)), _
                    parsedBitWidth, 64) <> 0 Then bitWidth = parsedBitWidth
                Exit For
            ElseIf tokens(i) = "(" Then
                ' Procedure-pointer members are handled by the signature reader.
                Exit Sub
            End If
        Next
        If nameIndex < 1 OrElse IsIdentifierToken(tokens(nameIndex)) = 0 Then Exit Sub
        Dim baseEnd As Long = nameIndex - 1
        While baseEnd >= 0 AndAlso (tokens(baseEnd) = "*" OrElse IsQualifierToken(tokens(baseEnd)) <> 0)
            baseEnd -= 1
        Wend
        If part = 0 Then
            For i As Long = 0 To baseEnd
                If i > 0 Then commonType &= " "
                commonType &= tokens(i)
            Next
            commonTypeTokenCount = baseEnd + 1
        End If
        Dim sourceType As String
        Dim pointerCount As Long = 0
        Dim isConst As Long = 0
        For i As Long = 0 To nameIndex - 1
            Select Case tokens(i)
            Case "*": pointerCount += 1
            Case "const", "__const", "__const__": isConst = -1
            Case "struct", "union", "volatile", "restrict", "__restrict", "__restrict__":
            Case Else
                If sourceType <> "" Then sourceType &= " "
                sourceType &= tokens(i)
            End Select
        Next
        If hasAnonymousEnumType <> 0 Then sourceType = "int"
        If nestedType <> "" Then sourceType = nestedType
        If isArray = 0 AndAlso pointerCount = 0 Then
            For aliasIndex As Long = 0 To translation.body.aliasCount - 1
                If translation.body.aliases(aliasIndex).name = sourceType AndAlso _
                   translation.body.aliases(aliasIndex).isArray <> 0 AndAlso _
                   translation.body.aliases(aliasIndex).ambiguous = 0 Then
                    isArray = -1
                    arrayBound = Trim(Str( _
                        translation.body.aliases(aliasIndex).arrayCount))
                    Exit For
                End If
            Next
        End If
        If CBodyRecordFieldIndex(translation, catalog, ownerName, tokens(nameIndex)) >= 0 Then Exit Sub
        Dim bitOffset As Long = 0
        If bitWidth >= 0 Then
            ' SQLite's nested flag records use consecutive unsigned-int
            ' bitfields. Retain the offset within that storage word so a
            ' read can be lowered to a mask against the port's raw flag field.
            For previousField As Long = translation.body.recordFieldCount - 1 To 0 Step -1
                If translation.body.recordFields(previousField).ownerName <> ownerName Then Continue For
                If translation.body.recordFields(previousField).bitWidth >= 0 AndAlso _
                   translation.body.recordFields(previousField).sourceType = sourceType Then
                    bitOffset = translation.body.recordFields(previousField).bitOffset + _
                                translation.body.recordFields(previousField).bitWidth
                    If bitOffset + bitWidth > 32 Then bitOffset = 0
                End If
                Exit For
            Next
        End If
        If translation.body.recordFieldCount >= _
           MAX_C2FB_BODY_RECORD_FIELDS Then _
            ReportError("C record fields exceed the configured limit")
        If translation.body.recordFieldCount > UBound(translation.body.recordFields) Then _
            ReDim Preserve translation.body.recordFields(0 To UBound(translation.body.recordFields) * 2 + 1)
        With translation.body.recordFields(translation.body.recordFieldCount)
            .ownerName = ownerName
            .name = tokens(nameIndex)
            .freeBasicName = CBodyFreeBasicFieldNameInContext( _
                translation, ownerName, .name)
            .sourceType = sourceType
            .nestedRecordKind = nestedTypeKind
            .pointerCount = pointerCount
            .isConst = isConst
            .volatileMask = C2fbVolatileQualifierMask( _
                tokens(), 0, nameIndex - 1)
            .isArray = isArray
            .isFlexibleArray = CInt(isArray <> 0 AndAlso arrayBound = "")
            .arrayBound = arrayBound
            .bitWidth = bitWidth
            .bitOffset = bitOffset
            .anonymousUnionGroup = anonymousUnionGroup
        End With
        translation.body.recordFieldCount += 1
        IndexCBodyRecordField( _
            translation, translation.body.recordFieldCount - 1)
End Sub

Declare Function RecordCBodyFieldsFromModel( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal ownerName As String, ByRef declaration As C2fbDeclarationModel, _
    ByVal depth As Long, ByVal anonymousUnionGroup As Long _
) As Long

Declare Function CBodyEnumDefinitionOpeningBrace( _
    ByVal sourceText As String, ByVal bracePosition As Long _
) As Long

Private Function RecordCBodyFieldsFromModel( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal ownerName As String, ByRef declaration As C2fbDeclarationModel, _
    ByVal depth As Long, ByVal anonymousUnionGroup As Long _
) As Long
    If depth >= 32 OrElse declaration.recordFieldsComplete = 0 Then Return 0
    If declaration.recordFieldCount = 0 Then
        If Trim(declaration.recordBody) = "" Then Return -1
        Return 0
    End If

    For fieldIndex As Long = 0 To declaration.recordFieldCount - 1
        With declaration.recordFields(fieldIndex)
            Dim nestedOpening As Long = 0
            Dim nestedTag As String
            Dim nestedRecordKind As C2fbRecordKind = C2FB_RECORD_KIND_NONE
            Dim parenDepth As Long = 0
            Dim bracketDepth As Long = 0
            Dim quoteByte As Long = 0
            Dim escaped As Long = 0
            Dim ignoredEnumEnd As Long = 0
            For position As Long = 1 To Len(.text)
                If position <= ignoredEnumEnd Then Continue For
                Dim currentByte As Long = Asc(.text, position)
                If quoteByte <> 0 Then
                    If escaped <> 0 Then
                        escaped = 0
                    ElseIf currentByte = Asc(Chr(92)) Then
                        escaped = -1
                    ElseIf currentByte = quoteByte Then
                        quoteByte = 0
                    End If
                ElseIf currentByte = Asc("'") OrElse _
                       currentByte = Asc(Chr(34)) Then
                    quoteByte = currentByte
                ElseIf currentByte = Asc("(") Then
                    parenDepth += 1
                ElseIf currentByte = Asc(")") Then
                    If parenDepth > 0 Then parenDepth -= 1
                ElseIf currentByte = Asc("[") Then
                    bracketDepth += 1
                ElseIf currentByte = Asc("]") Then
                    If bracketDepth > 0 Then bracketDepth -= 1
                ElseIf currentByte = Asc("{") AndAlso _
                       parenDepth = 0 AndAlso bracketDepth = 0 Then
                    If CBodyEnumDefinitionOpeningBrace(.text, position) <> 0 Then
                        Dim enumEnd As Long = position
                        If ScanSimpleExpressionGroup( _
                            .text, enumEnd, Asc("{"), Asc("}")) = 0 Then Return 0
                        ignoredEnumEnd = enumEnd - 1
                        Continue For
                    End If
                    Dim isRecord As Long
                    nestedTag = CBodyRecordTag( _
                        Left(.text, position - 1), isRecord, nestedRecordKind)
                    If isRecord = 0 Then Return 0
                    nestedOpening = position
                    Exit For
                End If
            Next

            If nestedOpening > 0 Then
                Dim nestedEnd As Long = nestedOpening
                If ScanSimpleExpressionGroup( _
                    .text, nestedEnd, Asc("{"), Asc("}")) = 0 Then Return 0
                Dim nestedBody As String = Mid( _
                    .text, nestedOpening + 1, nestedEnd - nestedOpening - 2)
                Dim nestedModel As C2fbDeclarationModel
                nestedModel.entryKind = C2FB_DECLARATION_RECORD
                nestedModel.recordKind = nestedRecordKind
                nestedModel.recordBody = nestedBody
                BuildC2fbRecordFieldSources(nestedModel)

                Dim nestedTail As String = Trim(Mid(.text, nestedEnd))
                If nestedTail = "" Then
                    If nestedTag = "" Then nestedTag = ownerName
                    Dim childAnonymousUnionGroup As Long = _
                        anonymousUnionGroup
                    If nestedRecordKind = C2FB_RECORD_UNION AndAlso _
                       childAnonymousUnionGroup = 0 Then
                        translation.body.anonymousUnionSerial += 1
                        childAnonymousUnionGroup = _
                            translation.body.anonymousUnionSerial
                    End If
                    If nestedModel.recordFieldsComplete = 0 OrElse _
                       RecordCBodyFieldsFromModel( _
                           translation, catalog, nestedTag, nestedModel, _
                           depth + 1, childAnonymousUnionGroup) = 0 Then Return 0
                Else
                    Dim tailTokens() As String
                    Dim tailCount As Long
                    TokenizeCDeclaration(nestedTail, tailTokens(), tailCount)
                    Dim fieldName As String
                    For tailIndex As Long = 0 To tailCount - 1
                        If IsIdentifierToken(tailTokens(tailIndex)) <> 0 Then
                            fieldName = tailTokens(tailIndex)
                            Exit For
                        End If
                    Next
                    If fieldName = "" Then Return 0
                    If nestedTag = "" Then _
                        nestedTag = ownerName & "." & fieldName
                    If nestedModel.recordFieldsComplete = 0 OrElse _
                       RecordCBodyFieldsFromModel( _
                           translation, catalog, nestedTag, nestedModel, _
                           depth + 1, 0) = 0 Then Return 0
                    Dim nestedKeyword As String = "struct "
                    If nestedRecordKind = C2FB_RECORD_UNION Then _
                        nestedKeyword = "union "
                    RecordCBodyField( _
                        translation, catalog, ownerName, _
                        nestedKeyword & fieldName & " " & nestedTail, nestedTag, _
                        nestedModel.recordKind, anonymousUnionGroup)
                End If
                Continue For
            End If

            Dim parts() As String
            Dim partCount As Long
            If SplitSimpleCList(.text, parts(), partCount) = 0 OrElse _
               partCount = 0 Then
                RecordCBodyField( _
                    translation, catalog, ownerName, .text, "", _
                    C2FB_RECORD_KIND_NONE, anonymousUnionGroup)
                Continue For
            End If
            Dim tokenRanges() As C2fbTokenRangeModel
            Dim tokenRangeCount As Long = 0
            Dim sourceRangesReady As Long = 0
            If .tokenCount > 0 AndAlso _
               SplitC2fbTokenList( _
                   .tokens(), 0, .tokenCount - 1, _
                   tokenRanges(), tokenRangeCount) <> 0 AndAlso _
               tokenRangeCount = partCount Then
                sourceRangesReady = -1
            End If
            If sourceRangesReady = 0 Then
                RecordCBodyField( _
                    translation, catalog, ownerName, .text, "", _
                    C2FB_RECORD_KIND_NONE, anonymousUnionGroup)
                Continue For
            End If

            Dim commonType As String
            Dim commonTypeTokenCount As Long = 0
            For partIndex As Long = 0 To partCount - 1
                Dim itemTokens() As String
                Dim itemTokenCount As Long = 0
                If BuildC2fbDeclaratorPartTokens( _
                    .tokens(), tokenRanges(), tokenRangeCount, partIndex, _
                    commonTypeTokenCount, itemTokens(), itemTokenCount) = 0 Then _
                    Continue For
                Dim itemDeclaration As String = parts(partIndex)
                If partIndex > 0 Then _
                    itemDeclaration = commonType & " " & itemDeclaration
                RecordCBodyFieldWithTokens( _
                    translation, catalog, ownerName, itemDeclaration, _
                    itemTokens(), itemTokenCount, commonType, _
                    commonTypeTokenCount, partIndex, "", _
                    C2FB_RECORD_KIND_NONE, anonymousUnionGroup)
            Next
        End With
    Next
    Return -1
End Function

Private Function CBodyEnumDefinitionOpeningBrace( _
    ByVal sourceText As String, ByVal bracePosition As Long _
) As Long
    If bracePosition <= 1 Then Return 0
    Dim prefix As String = Trim(Left(sourceText, bracePosition - 1))
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(prefix, tokens(), tokenCount)
    If tokenCount = 0 Then Return 0
    If LCase(tokens(tokenCount - 1)) = "enum" Then Return -1
    If tokenCount > 1 AndAlso _
       LCase(tokens(tokenCount - 2)) = "enum" AndAlso _
       IsIdentifierToken(tokens(tokenCount - 1)) <> 0 Then Return -1
    Return 0
End Function

Declare Sub BuildCBodyRecordStaticInitializerBindings( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
)

Private Sub IndexCBodyRecordsFromDeclarations( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
)
    ReDim translation.body.recordFields(0 To 255)
    ReDim translation.body.recordBindings(0 To 127)
    translation.body.recordFieldCount = 0
    ResetC2fbStringIndexMap(translation.body.recordFieldIndex)
    ResetC2fbStringIndexMap(translation.body.recordFreeBasicNameIndex)
    translation.body.recordBindingCount = 0
    translation.body.localRecordSerial = 0
    translation.body.staticRecordSerial = 0
    translation.body.anonymousUnionSerial = 0

    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               .recordKind = C2FB_RECORD_ENUM Then Continue For
            Dim ownerName As String = .recordTag
            If ownerName = "" Then ownerName = .recordAlias
            If ownerName = "" AndAlso IsIdentifierToken(Trim(.recordTail)) <> 0 Then _
                ownerName = Trim(.recordTail)
            If ownerName = "" Then Continue For
            If .recordFieldsComplete = 0 Then Continue For
            If RecordCBodyFieldsFromModel( _
                translation, catalog, ownerName, _
                translation.sourceUnit.declarations(declarationIndex), 0, 0) = 0 Then
                Continue For
            End If
        End With
    Next

    ' Start from explicit C/BASIC type mappings. Nested types can then be
    ' matched through a same-named field without guessing a record's layout.
    For i As Long = 0 To translation.body.recordFieldCount - 1
        Dim owner As String = translation.body.recordFields(i).ownerName
        Dim tokens() As String
        Dim count As Long
        TokenizeCDeclaration(owner, tokens(), count)
        Dim resolvedRecordType As C2fbResolvedTypeModel
        ResolveC2fbTypeModel( _
            translation, catalog, tokens(), 0, count - 1, resolvedRecordType, _
            C2FB_POINTER_MAPPING_PRESERVE, C2FB_TYPE_MAPPING_BODY, _
            C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
        If resolvedRecordType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Continue For
        Dim fbType As String = resolvedRecordType.freeBasicType
        If CBodyRecordHasMappedField( _
            translation, catalog, fbType, i) <> 0 Then _
            BindCBodyRecord(translation, owner, fbType)
    Next
    For i As Long = 0 To translation.body.recordFieldCount - 1
        Dim owner As String = translation.body.recordFields(i).ownerName
        Dim fbType As String = MappedFbBodyRecord(translation, catalog, owner)
        If fbType = owner Then Continue For
        If CBodyRecordHasMappedField( _
            translation, catalog, fbType, i) <> 0 Then _
            BindCBodyRecord(translation, owner, fbType)
    Next
    ' Source-unit layouts sometimes provide the generated c2fb_ Type name
    ' without a separate alias declaration. Bind that conventional spelling
    ' when the FreeBASIC catalog has the record and the C member exists in it.
    ' The member check keeps this from treating a similarly named scalar or
    ' unrelated record as a C layout match.
    For i As Long = 0 To translation.body.recordFieldCount - 1
        Dim owner As String = translation.body.recordFields(i).ownerName
        If LookupCBodyRecordBindingInContext(translation, owner) <> "" Then _
            Continue For
        Dim fbType As String = "c2fb_" & owner
        If FbBodyRecordHasFieldModel(catalog, fbType) = 0 Then Continue For
        If CBodyRecordHasMappedField( _
            translation, catalog, fbType, i) <> 0 Then _
            BindCBodyRecord(translation, owner, fbType)
    Next
    ' Anonymous typedef records have no C tag for the ordinary name mapping
    ' pass. Match them through their typedef alias, then bind the underlying
    ' FreeBASIC record rather than the alias's pointer levels.
    For i As Long = 0 To translation.body.recordFieldCount - 1
        Dim owner As String = translation.body.recordFields(i).ownerName
        If LookupCBodyRecordBindingInContext(translation, owner) <> "" Then _
            Continue For
        For aliasIndex As Long = 0 To translation.body.aliasCount - 1
            With translation.body.aliases(aliasIndex)
                If .ambiguous <> 0 OrElse .isArray <> 0 OrElse _
                   .baseType <> owner Then Continue For
                Dim generatedAlias As String = MappedFbBodyTypeAlias( _
                    translation, catalog, .name)
                If generatedAlias = "" Then Continue For
                Dim recordType As String = _
                    ResolveFbBodyRecordAlias(catalog, generatedAlias)
                If Left(recordType, 6) = "Const " Then _
                    recordType = Mid(recordType, 7)
                While Right(recordType, 4) = " Ptr"
                    recordType = Left(recordType, Len(recordType) - 4)
                Wend
                If CBodyRecordHasMappedField( _
                    translation, catalog, recordType, i) <> 0 Then
                    BindCBodyRecord(translation, owner, recordType)
                    Exit For
                End If
            End With
        Next
    Next
    Dim changed As Long
    Do
        changed = 0
        For i As Long = 0 To translation.body.recordFieldCount - 1
            With translation.body.recordFields(i)
                Dim parentType As String = _
                    LookupCBodyRecordBindingInContext(translation, .ownerName)
                If parentType = "" OrElse _
                   LookupCBodyRecordBindingInContext(translation, .sourceType) <> "" Then Continue For
                Dim fieldIndex As Long = LookupFbBodyField( _
                    translation, catalog, parentType, .name, i)
                If fieldIndex < 0 Then Continue For
                Dim nestedType As String = catalog.bodyFields(fieldIndex).typeName
                If Left(nestedType, 6) = "Const " Then nestedType = Mid(nestedType, 7)
                While Right(nestedType, 4) = " Ptr"
                    nestedType = Left(nestedType, Len(nestedType) - 4)
                Wend
                nestedType = ResolveFbBodyRecordAlias(catalog, nestedType)
                Dim hasSourceRecord As Long = 0
                Dim hasFbRecord As Long = 0
                For j As Long = 0 To translation.body.recordFieldCount - 1
                    If translation.body.recordFields(j).ownerName = .sourceType Then hasSourceRecord = -1
                Next
                For j As Long = 0 To catalog.bodyFieldCount - 1
                    If catalog.bodyFields(j).ownerName = nestedType Then hasFbRecord = -1
                Next
                If hasSourceRecord <> 0 AndAlso hasFbRecord <> 0 Then
                    ' Anonymous nested C aggregates have a generated layout,
                    ' but the source-unit type include already emits that type.
                    BindCBodyRecord( _
                        translation, .sourceType, nestedType, 0, .nestedRecordKind)
                    changed = -1
                End If
            End With
        Next
    Loop While changed <> 0
End Sub

Private Function CBodyFieldType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal index As Long, _
    ByVal decayArrayField As Long = -1 _
) As String
    If index < 0 Then Return ""
    With translation.body.recordFields(index)
        If .callbackType <> "" Then Return .callbackType
        Dim typedefCallback As String = LookupCBodyCallbackTypeAlias( _
            translation, .sourceType)
        Dim levels As Long = .pointerCount
        If .isArray <> 0 AndAlso decayArrayField <> 0 Then levels += 1
        If typedefCallback <> "" Then
            Dim hasBodyTypedef As Long = 0
            For aliasIndex As Long = 0 To translation.body.aliasCount - 1
                If translation.body.aliases(aliasIndex).name = .sourceType Then
                    levels += translation.body.aliases(aliasIndex).pointerCount
                    hasBodyTypedef = -1
                    Exit For
                End If
            Next
            If hasBodyTypedef = 0 AndAlso _
               IsMappedFbBodyProcedureTypeAlias(catalog, typedefCallback) <> 0 Then _
                levels -= 1
            If levels < 0 Then Return ""
            Dim callbackType As String = typedefCallback
            For pointerIndex As Long = 1 To levels
                callbackType &= " Ptr"
            Next
            Return callbackType
        End If
        Dim arrayAliasSourceType As String = .sourceType
        If .pointerCount = 0 Then
            For aliasIndex As Long = 0 To translation.body.aliasCount - 1
                With translation.body.aliases(aliasIndex)
                    If .name <> arrayAliasSourceType OrElse .ambiguous <> 0 OrElse _
                       .isArray = 0 OrElse .arrayElementType = "" Then Continue For
                    Dim elementTokens() As String
                    Dim elementTokenCount As Long
                    TokenizeCDeclaration( _
                        .arrayElementType, elementTokens(), elementTokenCount)
                    If elementTokenCount = 0 Then Return ""
                    Dim resolvedElementType As C2fbResolvedTypeModel
                    ResolveC2fbTypeModel( _
                        translation, catalog, elementTokens(), 0, _
                        elementTokenCount - 1, resolvedElementType, _
                        C2FB_POINTER_MAPPING_PRESERVE, C2FB_TYPE_MAPPING_BODY)
                    If resolvedElementType.status <> _
                       C2FB_TYPE_RESOLUTION_RESOLVED Then Return ""
                    Dim elementType As String = resolvedElementType.freeBasicType
                    If .isConst <> 0 AndAlso Left(elementType, 6) <> "Const " Then _
                        elementType = "Const " & elementType
                    Return elementType & " Ptr"
                End With
            Next
        End If
        Dim baseType As String = _
            LookupCBodyRecordBindingInContext(translation, .sourceType)
        If baseType = "" Then
            Dim tokens() As String
            Dim count As Long
            TokenizeCDeclaration(.sourceType, tokens(), count)
            If C2fbTypeRecognitionStatusInContext( _
                translation, catalog, tokens(), 0, count - 1) <> _
               C2FB_TYPE_RESOLUTION_RESOLVED Then
                ' An unmapped record pointer still has a known pointer ABI.
                ' Keep it opaque until a BASIC layout is available; scalar
                ' operations and dereferencing still require an actual type.
                If .pointerCount = 0 Then Return ""
                baseType = "Any"
                For i As Long = 1 To levels
                    baseType &= " Ptr"
                Next
                Return baseType
            End If
            Dim declaration As String = .sourceType
            If .isConst <> 0 Then declaration = "const " & declaration
            For i As Long = 1 To levels
                declaration &= " *"
            Next
            TokenizeCDeclaration(declaration, tokens(), count)
            Dim resolvedFieldType As C2fbResolvedTypeModel
            ResolveC2fbTypeModel( _
                translation, catalog, tokens(), 0, count - 1, resolvedFieldType)
            If resolvedFieldType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return ""
            baseType = resolvedFieldType.freeBasicType
            If .bitWidth > 0 AndAlso .bitWidth < 32 AndAlso _
               (baseType = "SQLITE_C_UINT" OrElse baseType = "c2fb_c_uint") Then _
                baseType = "c2fb_c_int"
            Return baseType
        End If
        If .bitWidth > 0 AndAlso .bitWidth < 32 AndAlso _
           (baseType = "SQLITE_C_UINT" OrElse baseType = "c2fb_c_uint") Then _
            baseType = "c2fb_c_int"
        If .isConst <> 0 AndAlso levels > 0 Then baseType = "Const " & baseType
        For i As Long = 1 To levels
            baseType &= " Ptr"
        Next
        Return baseType
    End With
End Function

Private Sub BuildCBodyRecordStaticInitializerBindings( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
)
    For recordIndex As Long = 0 To translation.body.recordBindingCount - 1
        With translation.body.recordBindings(recordIndex)
            If .fbName = "" Then Continue For
            Dim itemCount As Long = 0
            For fieldIndex As Long = 0 To translation.body.recordFieldCount - 1
                If translation.body.recordFields(fieldIndex).ownerName = _
                   .sourceName OrElse _
                   translation.body.recordFields(fieldIndex).ownerName = _
                   .fbName Then itemCount += 1
            Next
            If itemCount <= 0 Then Continue For

            Dim initializerBinding As C2fbRecordBindingModel
            initializerBinding.freeBasicName = .fbName
            initializerBinding.isUnion = CInt( _
                .recordKind = C2FB_RECORD_UNION) * -1
            If .recordKind = C2FB_RECORD_KIND_NONE Then
                For declarationIndex As Long = 0 To _
                    translation.sourceUnit.declarationCount - 1
                    With translation.sourceUnit.declarations(declarationIndex)
                        If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
                           (.recordTag <> translation.body.recordBindings( _
                                recordIndex).sourceName AndAlso _
                            .recordAlias <> translation.body.recordBindings( _
                                recordIndex).sourceName) Then Continue For
                        initializerBinding.isUnion = CInt( _
                            .recordKind = C2FB_RECORD_UNION) * -1
                        Exit For
                    End With
                Next
            End If
            ReDim initializerBinding.items(0 To itemCount - 1)

            Dim itemIndex As Long = 0
            For fieldIndex As Long = 0 To translation.body.recordFieldCount - 1
                With translation.body.recordFields(fieldIndex)
                    If .ownerName <> translation.body.recordBindings( _
                        recordIndex).sourceName AndAlso _
                       .ownerName <> translation.body.recordBindings( _
                        recordIndex).fbName Then Continue For
                    Dim fieldType As String = CBodyFieldType( _
                        translation, catalog, fieldIndex, 0)
                    If fieldType = "" Then
                        itemCount = 0
                        Exit For
                    End If
                    With initializerBinding.items(itemIndex)
                        .kind = C2FB_RECORD_BINDING_ITEM_FIELD
                        .isUnion = initializerBinding.isUnion
                        .isBitField = CInt( _
                            translation.body.recordFields(fieldIndex).bitWidth >= 0) * -1
                        .name = translation.body.recordFields(fieldIndex).freeBasicName
                        .sourceName = translation.body.recordFields(fieldIndex).name
                        .fieldType = fieldType
                        If translation.body.recordFields(fieldIndex).isArray <> 0 Then
                            Dim fieldArrayCount As Long
                            If EvaluateGenericHeaderArrayBound( _
                                translation, _
                                translation.body.recordFields(fieldIndex).arrayBound, _
                                fieldArrayCount, MAX_GENERIC_ARRAY_COUNT) = 0 OrElse _
                               fieldArrayCount <= 0 Then
                                itemCount = 0
                                Exit For
                            End If
                            .arrayCount = fieldArrayCount
                            .arrayBounds = "0 To " & Trim(Str(fieldArrayCount - 1))
                        End If
                    End With
                    itemIndex += 1
                End With
            Next

            If itemCount <> itemIndex Then Continue For
            initializerBinding.itemCount = itemCount
            translation.body.recordBindings(recordIndex).staticInitializerBinding = _
                initializerBinding
        End With
    Next
End Sub

Private Function CBodyGenericFlexibleArrayAccessorName( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceFieldIndex As Long _
) As String
    If sourceFieldIndex < 0 OrElse _
       sourceFieldIndex >= translation.body.recordFieldCount Then Return ""

    Dim ownerName As String
    Dim fieldName As String
    With translation.body.recordFields(sourceFieldIndex)
        If .isArray = 0 OrElse _
           (.arrayBound <> "" AndAlso .arrayBound <> "0") OrElse _
           .bitWidth >= 0 Then Return ""
        ownerName = .ownerName
        fieldName = .name
    End With
    Dim elementType As String = CBodyFieldType( _
        translation, catalog, sourceFieldIndex)
    If elementType = "" OrElse elementType = "Any" OrElse _
       InStr(elementType, "CLongDouble") <> 0 Then Return ""
    If InStr(elementType, " Ptr") = 0 Then
        Dim elementRecord As String = CBodyRecordName( _
            translation, catalog, elementType)
        If elementRecord <> "" AndAlso CBodyRecordSizeIsKnown( _
            translation, catalog, elementRecord) = 0 Then Return ""
    End If

    ' The generated tail accessor is valid only for the final member in its
    ' C record. Keep this check independent of the FreeBASIC layout catalog,
    ' which intentionally has no storage field for the flexible array itself.
    For fieldIndex As Long = sourceFieldIndex + 1 To _
        translation.body.recordFieldCount - 1
        If translation.body.recordFields(fieldIndex).ownerName = ownerName Then _
            Return ""
    Next
    Dim generatedPrefix As String = translation.genericC.policy.generatedNamePrefix
    If generatedPrefix = "" Then generatedPrefix = "c2fb_"
    Dim fbRecordName As String = _
        MappedFbBodyRecord(translation, catalog, ownerName)
    If fbRecordName = "" Then Return ""

    If translation.target.profile = C2FB_TARGET_SQLITE Then
        ' SQLite's existing layouts use C2FB's generated record and tail
        ' accessor names together. Do not guess a custom mapped layout's ABI.
        If fbRecordName <> generatedPrefix & ownerName Then Return ""
    End If

    Return generatedPrefix & ownerName & "_" & fieldName & "_tail_ptr"
End Function

Private Function CBodyGeneratedSourceRecordIsSafe( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceName As String, ByVal declarationIndex As Long, _
    ByVal allowPointerCallbacks As Long = 0 _
) As Long
    If declarationIndex < 0 OrElse _
       declarationIndex >= translation.sourceUnit.declarationCount Then Return 0
    With translation.sourceUnit.declarations(declarationIndex)
        If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
           (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
            .recordKind <> C2FB_RECORD_UNION) OrElse _
           .isConditional <> 0 OrElse .isPacked <> 0 OrElse _
           .recordAlignment <> 0 OrElse _
           .recordFieldsComplete = 0 OrElse _
           C2fbCTextContainsIdentifier(.recordBody, "__attribute__") <> 0 OrElse _
           C2fbCTextContainsIdentifier(.recordBody, "__declspec") <> 0 OrElse _
           C2fbCTextContainsIdentifier(.recordBody, "__aligned__") <> 0 OrElse _
           C2fbCTextContainsIdentifier(.recordBody, "__packed__") <> 0 OrElse _
           C2fbCTextContainsIdentifier(.recordBody, "volatile") <> 0 Then Return 0
    End With

    ' Nested record fields are safe only when their complete storage size is
    ' known. The field checks below validate those dependencies before emit.
    Dim fieldCount As Long = 0
    For fieldIndex As Long = 0 To translation.body.recordFieldCount - 1
        With translation.body.recordFields(fieldIndex)
            If .ownerName <> sourceName Then Continue For
            If (.callbackType <> "" AndAlso allowPointerCallbacks = 0) OrElse _
               .bitWidth >= 0 OrElse _
               (.isConst <> 0 AndAlso .pointerCount = 0) Then _
                Return 0
            If .callbackType <> "" Then
                fieldCount += 1
                Continue For
            End If
            Dim fieldType As String = CBodyFieldType( _
                translation, catalog, fieldIndex)
            If fieldType = "" OrElse fieldType = "Any" OrElse _
               (.pointerCount = 0 AndAlso _
                InStr(fieldType, "CLongDouble") <> 0) Then Return 0
            If .isArray <> 0 Then
                Dim arrayCount As Long
                If EvaluateSimpleArrayBound( _
                    .arrayBound, arrayCount, MAX_SIMPLE_ARRAY_COUNT) = 0 OrElse _
                   arrayCount < 1 Then Return 0
                Dim elementType As String = SimplePointeeType(fieldType)
                If elementType = "" Then Return 0
                If .pointerCount = 0 Then
                    Dim nestedRecord As String = CBodyRecordName( _
                        translation, catalog, elementType)
                    If nestedRecord <> "" Then
                        If CBodyRecordSizeIsKnown( _
                            translation, catalog, nestedRecord) = 0 Then Return 0
                    Else
                        Dim typeTokens() As String
                        Dim typeTokenCount As Long
                        TokenizeCDeclaration( _
                            .sourceType, typeTokens(), typeTokenCount)
                        If typeTokenCount = 0 Then Return 0
                        Dim resolvedType As C2fbResolvedTypeModel
                        ResolveC2fbTypeModel( _
                            translation, catalog, typeTokens(), 0, _
                            typeTokenCount - 1, resolvedType, _
                            C2FB_POINTER_MAPPING_PRESERVE, _
                            C2FB_TYPE_MAPPING_BODY, _
                            C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
                        If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
                           resolvedType.pointerCount <> 0 Then Return 0
                    End If
                End If
            ElseIf .pointerCount > 0 Then
                If InStr(fieldType, " Ptr") = 0 Then Return 0
            Else
                If InStr(fieldType, " Ptr") <> 0 Then Return 0
                Dim nestedRecord As String = CBodyRecordName( _
                    translation, catalog, fieldType)
                If nestedRecord <> "" Then
                    If CBodyRecordSizeIsKnown( _
                        translation, catalog, nestedRecord) = 0 Then Return 0
                Else
                    Dim typeTokens() As String
                    Dim typeTokenCount As Long
                    TokenizeCDeclaration( _
                        .sourceType, typeTokens(), typeTokenCount)
                    If typeTokenCount = 0 Then Return 0
                    Dim resolvedType As C2fbResolvedTypeModel
                    ResolveC2fbTypeModel( _
                        translation, catalog, typeTokens(), 0, _
                        typeTokenCount - 1, resolvedType, _
                        C2FB_POINTER_MAPPING_PRESERVE, _
                        C2FB_TYPE_MAPPING_BODY, _
                        C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
                    If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
                       resolvedType.pointerCount <> 0 Then Return 0
                End If
            End If
            fieldCount += 1
        End With
    Next
    Return CInt(fieldCount > 0)
End Function

Private Function CBodyStoragePointerDepth(ByVal typeName As String) As Long
    Dim pointerDepth As Long = 0
    If Left(typeName, 6) = "Const " Then typeName = Mid(typeName, 7)
    While Right(typeName, 4) = " Ptr"
        typeName = Left(typeName, Len(typeName) - 4)
        pointerDepth += 1
    Wend
    Return pointerDepth
End Function

Private Function CBodyMappedRecordLayoutMatchesActiveC( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As Long
    Dim mappedRecord As String = _
        MappedFbBodyRecord(translation, catalog, sourceName)
    If mappedRecord = "" OrElse _
       CBodyRecordHasUnmeasuredFlexibleTail(translation, sourceName) <> 0 Then _
        Return 0

    Dim sourceDeclarationIndex As Long = -1
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) OrElse _
               (.recordTag <> sourceName AndAlso _
                .recordAlias <> sourceName) Then Continue For
            If sourceDeclarationIndex >= 0 Then Return 0
            sourceDeclarationIndex = declarationIndex
        End With
    Next
    If CBodyGeneratedSourceRecordIsSafe( _
        translation, catalog, sourceName, sourceDeclarationIndex, _
        CInt(sourceName = "BtShared")) = 0 Then _
        Return 0

    Dim mappedOwner As String = ResolveFbBodyRecordOwner( _
        catalog, mappedRecord)
    Dim cFieldCount As Long = 0
    Dim fbFieldCount As Long = 0
    For cField As Long = 0 To translation.body.recordFieldCount - 1
        With translation.body.recordFields(cField)
            If .ownerName <> sourceName Then Continue For
            If .isArray <> 0 OrElse .bitWidth >= 0 OrElse _
               (.callbackType <> "" AndAlso sourceName <> "BtShared") Then _
                Return 0
            cFieldCount += 1
        End With
    Next
    For fbField As Long = 0 To catalog.bodyFieldCount - 1
        If LCase(catalog.bodyFields(fbField).ownerName) <> _
           LCase(mappedOwner) Then Continue For
        If sourceName = "Btree" AndAlso _
           LCase(catalog.bodyFields(fbField).name) = "nseek" Then
            Dim activeCFieldExists As Long = 0
            For cField As Long = 0 To translation.body.recordFieldCount - 1
                If translation.body.recordFields(cField).ownerName = sourceName AndAlso _
                   LCase(translation.body.recordFields(cField).name) = "nseek" Then
                    activeCFieldExists = -1
                    Exit For
                End If
            Next
            ' nSeek is guarded by SQLITE_DEBUG in both source declarations.
            If activeCFieldExists = 0 Then Continue For
        End If
        If catalog.bodyFields(fbField).isArray <> 0 Then Return 0
        fbFieldCount += 1
    Next
    If cFieldCount <= 0 OrElse cFieldCount <> fbFieldCount Then Return 0

    Dim previousFbFieldIndex As Long = -1
    For cField As Long = 0 To translation.body.recordFieldCount - 1
        With translation.body.recordFields(cField)
            If .ownerName <> sourceName Then Continue For

            Dim fbFieldName As String = CBodyFreeBasicFieldNameForAccess( _
                translation, sourceName, .name, cField)
            Dim fbFieldIndex As Long = -1
            For candidateField As Long = previousFbFieldIndex + 1 To _
                catalog.bodyFieldCount - 1
                With catalog.bodyFields(candidateField)
                    If LCase(.ownerName) = LCase(mappedOwner) AndAlso _
                       Not (sourceName = "Btree" AndAlso _
                            LCase(.name) = "nSeek" AndAlso _
                            translation.body.recordFields(cField).name <> "nSeek") AndAlso _
                       LCase(.name) = LCase(fbFieldName) Then
                        fbFieldIndex = candidateField
                        Exit For
                    End If
                End With
            Next
            If fbFieldIndex < 0 Then Return 0

            Dim normalizedFbType As String = NormalizeFbBodyType( _
                catalog, catalog.bodyFields(fbFieldIndex).typeName)
            If translation.body.recordFields(cField).callbackType <> "" Then
                ' The port stores this C function pointer in pointer-sized storage.
                If sourceName <> "BtShared" OrElse _
                   CBodyStoragePointerDepth(normalizedFbType) <> 1 Then Return 0
            Else
                Dim cFieldType As String = CBodyFieldType( _
                    translation, catalog, cField)
                If cFieldType = "" Then Return 0
                Dim normalizedCType As String = NormalizeFbBodyType( _
                    catalog, cFieldType)
                If LCase(normalizedCType) <> LCase(normalizedFbType) Then
                    Dim cPointerDepth As Long = _
                        CBodyStoragePointerDepth(normalizedCType)
                    Dim fbPointerDepth As Long = _
                        CBodyStoragePointerDepth(normalizedFbType)
                    If cPointerDepth = 0 OrElse _
                       cPointerDepth <> fbPointerDepth Then Return 0
                End If
            End If
            previousFbFieldIndex = fbFieldIndex
        End With
    Next
    Return -1
End Function

Private Sub IndexCBodyGeneratedSourceRecords( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
)
    Dim declarationCapacity As Long = _
        translation.sourceUnit.declarationCount
    If declarationCapacity <= 0 Then Exit Sub
    Dim completeDefinitionMap As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(completeDefinitionMap)
    Dim completeDefinitionCounts() As Long
    Dim completeDefinitionIndices() As Long
    ReDim completeDefinitionCounts(0 To declarationCapacity - 1)
    ReDim completeDefinitionIndices(0 To declarationCapacity - 1)
    Dim completeDefinitionNameCount As Long = 0

    For declarationIndex As Long = 0 To declarationCapacity - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) OrElse _
               .isBlockLocal <> 0 OrElse .isConditional <> 0 OrElse _
               .recordFieldsComplete = 0 Then Continue For
            Dim sourceName As String = .recordTag
            If sourceName = "" Then sourceName = .recordAlias
            If sourceName = "" Then Continue For
            Dim definitionIndex As Long = _
                C2fbStringIndexMapLookup(completeDefinitionMap, sourceName)
            If definitionIndex < 0 Then
                definitionIndex = completeDefinitionNameCount
                If AddC2fbStringIndexMapEntry( _
                    completeDefinitionMap, sourceName, definitionIndex) = 0 Then _
                    ReportError("source record definition index exceeds its configured limit")
                completeDefinitionNameCount += 1
            End If
            completeDefinitionCounts(definitionIndex) += 1
            completeDefinitionIndices(definitionIndex) = declarationIndex
        End With
    Next

    For declarationIndex As Long = 0 To _
        declarationCapacity - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) OrElse _
               .isBlockLocal <> 0 OrElse .isConditional <> 0 OrElse _
               .recordFieldsComplete = 0 Then Continue For

            Dim sourceRecordKind As C2fbRecordKind = .recordKind
            Dim sourceName As String = .recordTag
            If sourceName = "" Then sourceName = .recordAlias
            If sourceName = "" OrElse _
               LookupCBodyRecordBindingInContext(translation, sourceName) <> "" Then _
                Continue For
            If GenericTypeOverrideInPolicy( _
                translation.genericC.policy, sourceName) <> "" OrElse _
               (.recordAlias <> "" AndAlso GenericTypeOverrideInPolicy( _
                   translation.genericC.policy, .recordAlias) <> "") Then Continue For
            Dim definitionIndex As Long = _
                C2fbStringIndexMapLookup(completeDefinitionMap, sourceName)
            If definitionIndex < 0 OrElse _
               completeDefinitionCounts(definitionIndex) <> 1 OrElse _
               completeDefinitionIndices(definitionIndex) <> declarationIndex Then _
                Continue For
            ' A recognized CDecl callback field is a pointer-sized slot that
            ' FreeBASIC can retain in the generated private layout.
            If CBodyGeneratedSourceRecordIsSafe( _
                translation, catalog, sourceName, declarationIndex, -1) = 0 Then _
                Continue For

            Dim generatedName As String
            Do
                If translation.body.localRecordSerial >= _
                   MAX_C2FB_BODY_RECORD_BINDINGS Then _
                    ReportError("generated source records exceed the configured limit")
                generatedName = "c2fb_source_record_" & _
                    Trim(Str(translation.body.localRecordSerial))
                translation.body.localRecordSerial += 1
                Dim nameAvailable As Long = CInt( _
                    C2fbStringIndexMapLookup( _
                        catalog.bodyTypeAliasMap, LCase(generatedName)) < 0)
                For existingField As Long = 0 To catalog.bodyFieldCount - 1
                    If LCase(catalog.bodyFields(existingField).ownerName) = _
                       LCase(generatedName) Then
                        nameAvailable = 0
                        Exit For
                    End If
                Next
                If nameAvailable <> 0 Then Exit Do
            Loop

            If translation.body.recordBindingCount >= _
               MAX_C2FB_BODY_RECORD_BINDINGS Then _
                ReportError("generated source record bindings exceed the configured limit")
            If translation.body.recordBindingCount > _
               UBound(translation.body.recordBindings) Then _
                ReDim Preserve translation.body.recordBindings( _
                    0 To UBound(translation.body.recordBindings) * 2 + 1)
            With translation.body.recordBindings(translation.body.recordBindingCount)
                .sourceName = sourceName
                .fbName = generatedName
                .recordKind = sourceRecordKind
                .isGenerated = -1
            End With
            translation.body.recordBindingCount += 1

            Dim savedBodyFieldCount As Long = catalog.bodyFieldCount
            Dim generationAccepted As Long = -1
            For fieldIndex As Long = 0 To translation.body.recordFieldCount - 1
                With translation.body.recordFields(fieldIndex)
                    If .ownerName <> sourceName Then Continue For
                    Dim fieldType As String = CBodyFieldType( _
                        translation, catalog, fieldIndex)
                    If fieldType = "" Then
                        generationAccepted = 0
                        Exit For
                    End If
                    Dim storedFieldType As String = fieldType
                    If translation.body.recordFields(fieldIndex).isArray <> 0 Then
                        storedFieldType = SimplePointeeType(fieldType)
                        If storedFieldType = "" Then
                            generationAccepted = 0
                            Exit For
                        End If
                    End If
                    If catalog.bodyFieldCount >= MAX_C2FB_BODY_CATALOG_FIELDS Then _
                        ReportError("generated source record fields exceed the configured limit")
                    If catalog.bodyFieldCount > UBound(catalog.bodyFields) Then _
                        ReDim Preserve catalog.bodyFields( _
                            0 To UBound(catalog.bodyFields) * 2 + 1)
                    With catalog.bodyFields(catalog.bodyFieldCount)
                        .ownerName = generatedName
                        .name = _
                            translation.body.recordFields(fieldIndex).freeBasicName
                        If .name = "" Then _
                            .name = translation.body.recordFields(fieldIndex).name
                        .typeName = storedFieldType
                        .isArray = translation.body.recordFields(fieldIndex).isArray
                        .isUnionMember = 0
                        .isPrivate = 0
                        .headerName = ""
                    End With
                    catalog.bodyFieldCount += 1
                    IndexC2fbBodyField( _
                        catalog, catalog.bodyFieldCount - 1)
                End With
            Next
            If generationAccepted = 0 Then
                translation.body.recordBindingCount -= 1
                catalog.bodyFieldCount = savedBodyFieldCount
                RebuildC2fbBodyFieldIndex(catalog)
            End If
        End With
    Next
End Sub

Private Function CBodyFieldBitFieldSignedness( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal index As Long _
) As Long
    If index < 0 OrElse translation.body.recordFields(index).bitWidth < 0 Then _
        Return C2FB_BITFIELD_SIGNEDNESS_UNKNOWN
    Dim tokens() As String
    Dim count As Long
    TokenizeCDeclaration(translation.body.recordFields(index).sourceType, tokens(), count)
    If count = 0 Then Return C2FB_BITFIELD_SIGNEDNESS_UNKNOWN
    Dim resolvedFieldType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        translation, catalog, tokens(), 0, count - 1, resolvedFieldType)
    If resolvedFieldType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then _
        Return C2FB_BITFIELD_SIGNEDNESS_UNKNOWN
    Dim fieldType As String = resolvedFieldType.freeBasicType
    Select Case fieldType
    Case "Byte", "Short", "Long", "CLong", "LongInt", "Integer", _
         "SQLITE_C_INT", "SQLITE_C_LONG", "sqlite3_int64", _
         "c2fb_c_int", "c2fb_c_long", "c2fb_int64"
        Return C2FB_BITFIELD_SIGNEDNESS_SIGNED
    Case "UByte", "UShort", "ULong", "CULong", "ULongInt", "UInteger", _
         "SQLITE_C_UINT", "SQLITE_C_ULONG", "sqlite3_uint64", _
         "c2fb_c_uint", "c2fb_c_ulong", "c2fb_uint64"
        Return C2FB_BITFIELD_SIGNEDNESS_UNSIGNED
    End Select

    ' On the GCC target, enum bitfields with only nonnegative enumerators are
    ' unsigned. Preserve their high bits when the BASIC enum alias is Long.
    Dim sourceType As String = _
        Trim(translation.body.recordFields(index).sourceType)
    Dim enumSourceType As String = ""
    Dim sourceTypeTokens() As String
    Dim sourceTypeTokenCount As Long = 0
    TokenizeCDeclaration(sourceType, sourceTypeTokens(), sourceTypeTokenCount)
    For tokenIndex As Long = 0 To sourceTypeTokenCount - 1
        If sourceTypeTokens(tokenIndex) = "enum" Then
            If tokenIndex + 1 < sourceTypeTokenCount Then _
                enumSourceType = sourceTypeTokens(tokenIndex + 1)
            Exit For
        ElseIf IsIdentifierToken(sourceTypeTokens(tokenIndex)) <> 0 AndAlso _
               IsQualifierToken(sourceTypeTokens(tokenIndex)) = 0 Then
            enumSourceType = sourceTypeTokens(tokenIndex)
        End If
    Next
    If enumSourceType <> "" Then
        Dim enumMemberFound As Long = 0
        Dim enumValuesKnown As Long = -1
        Dim enumHasNegativeValue As Long = 0
        For enumIndex As Long = 0 To _
            translation.genericC.header.enumMemberCount - 1
            With translation.genericC.header.enumMembers(enumIndex)
                If .enumTypeName <> enumSourceType AndAlso _
                   .enumTagName <> enumSourceType Then Continue For
                enumMemberFound = -1
                If .integerValueKnown = 0 Then
                    enumValuesKnown = 0
                ElseIf .integerValue < 0 Then
                    enumHasNegativeValue = -1
                End If
            End With
        Next
        If enumMemberFound <> 0 AndAlso enumValuesKnown <> 0 Then
            If enumHasNegativeValue <> 0 Then _
                Return C2FB_BITFIELD_SIGNEDNESS_SIGNED
            Return C2FB_BITFIELD_SIGNEDNESS_UNSIGNED
        End If
    End If
    Return C2FB_BITFIELD_SIGNEDNESS_UNKNOWN
End Function

/' end of c2fb_c_records.bi '/
