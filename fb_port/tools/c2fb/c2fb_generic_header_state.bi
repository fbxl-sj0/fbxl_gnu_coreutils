/'
    Project: C2FB generic header type state
    ----------------------------------------

    File: c2fb_generic_header_state.bi

    Purpose:

        Own generic-header aliases and type adjustments derived from them.

    Responsibilities:

        - Record, look up, emit, and remove generic-header type aliases by C and FreeBASIC name.
        - Resolve alias storage types and function-alias signatures.
        - Apply string type conversions using header alias state.

    This file intentionally does NOT contain:

        - Generic C option parsing or caller policy storage.
        - Target ABI selection or generated-file formatting.
'/

Private Function GenericHeaderTypeAliasIndexInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal sourceName As String, ByVal isTag As Long = 0 _
) As Long
    If headerState.typeAliasIndex.capacity > 0 Then
        Return C2fbStringIndexMapLookup( _
            headerState.typeAliasIndex, _
            IIf(isTag <> 0, "T", "I") & sourceName)
    End If
    For i As Long = 0 To headerState.headerTypeAliasCount - 1
        If headerState.headerTypeAliases(i).sourceName = sourceName AndAlso _
           headerState.headerTypeAliases(i).isTag = isTag Then Return i
    Next
    Return -1
End Function

Private Function GenericHeaderTypeAliasIndexByFreeBasicNameInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal freeBasicName As String _
) As Long
    If freeBasicName = "" Then Return -1
    Dim canonicalName As String = LCase(freeBasicName)
    If headerState.freeBasicTypeAliasIndex.capacity > 0 Then
        Return C2fbStringIndexMapLookup( _
            headerState.freeBasicTypeAliasIndex, canonicalName)
    End If
    For aliasIndex As Long = 0 To headerState.headerTypeAliasCount - 1
        If LCase(headerState.headerTypeAliases(aliasIndex).freeBasicName) = _
           canonicalName Then Return aliasIndex
    Next
    Return -1
End Function

Private Sub RebuildGenericHeaderTypeAliasIndex( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel _
)
    ResetC2fbStringIndexMap(headerState.typeAliasIndex)
    ResetC2fbStringIndexMap(headerState.freeBasicTypeAliasIndex)
    For aliasIndex As Long = 0 To headerState.headerTypeAliasCount - 1
        With headerState.headerTypeAliases(aliasIndex)
            Dim key As String = IIf(.isTag <> 0, "T", "I") & .sourceName
            If AddC2fbStringIndexMapEntry( _
                headerState.typeAliasIndex, key, aliasIndex) <> -1 Then _
                ReportError("generic header type-alias index exceeds its configured limit")
            Dim freeBasicKey As String = LCase(.freeBasicName)
            If C2fbStringIndexMapLookup( _
                headerState.freeBasicTypeAliasIndex, freeBasicKey) < 0 AndAlso _
               AddC2fbStringIndexMapEntry( _
                headerState.freeBasicTypeAliasIndex, freeBasicKey, aliasIndex) = 0 Then _
                ReportError("generic header FreeBASIC type-alias index exceeds its configured limit")
        End With
    Next
End Sub


Private Function GenericHeaderTagAliasNameInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, ByVal sourceName As String _
) As String
    Dim index As Long = GenericHeaderTypeAliasIndexInHeader(headerState, sourceName, -1)
    If index < 0 Then Return ""
    Return headerState.headerTypeAliases(index).freeBasicName
End Function

Private Function GenericHeaderTypeAliasStorageTypeInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal freeBasicName As String, ByVal depth As Long _
) As String
    If depth >= 32 Then Return ""
    Dim aliasIndex As Long = GenericHeaderTypeAliasIndexByFreeBasicNameInHeader( _
        headerState, freeBasicName)
    If aliasIndex < 0 Then Return ""
    Dim baseType As String = headerState.headerTypeAliases(aliasIndex).baseType
    If GenericHeaderTypeAliasIndexByFreeBasicNameInHeader( _
        headerState, baseType) >= 0 Then _
        Return GenericHeaderTypeAliasStorageTypeInHeader( _
            headerState, baseType, depth + 1)
    Return baseType
End Function

Private Function GenericHeaderTypeIsOpaqueEmptyRecordInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal freeBasicType As String _
) As Long
    freeBasicType = Trim(freeBasicType)
    If Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Trim(Mid(freeBasicType, 7))
    If InStr(freeBasicType, " Ptr") <> 0 Then Return 0
    Return CInt(GenericHeaderTypeAliasStorageTypeInHeader( _
        headerState, freeBasicType, 0) = "Any") * -1
End Function

Private Function GenericFreeBasicTypePointerDepthInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal freeBasicType As String, ByVal depth As Long _
) As Long
    If depth >= 32 Then Return MAX_FREEBASIC_POINTER_LEVELS + 1
    freeBasicType = Trim(freeBasicType)
    If Left(freeBasicType, 6) = "Const " Then freeBasicType = Mid(freeBasicType, 7)
    If Left(freeBasicType, 9) = "Function " OrElse _
       Left(freeBasicType, 4) = "Sub " Then Return 1

    Dim pointerDepth As Long = 0
    While Right(freeBasicType, 4) = " Ptr"
        freeBasicType = RTrim(Left(freeBasicType, Len(freeBasicType) - 4))
        pointerDepth += 1
    Wend
    Dim aliasIndex As Long = GenericHeaderTypeAliasIndexByFreeBasicNameInHeader( _
        headerState, freeBasicType)
    If aliasIndex < 0 Then Return pointerDepth
    Dim baseType As String = headerState.headerTypeAliases(aliasIndex).baseType
    If baseType = "" OrElse baseType = "Record" Then Return pointerDepth
    Return pointerDepth + GenericFreeBasicTypePointerDepthInHeader( _
        headerState, baseType, depth + 1)
End Function

Private Function ApplyGenericStringOverrideInGenericC( _
    ByRef genericC As C2fbGenericCTranslationStateModel, _
    ByVal sourceName As String, ByVal freeBasicType As String _
) As String
    Return ApplyGenericStringOverrideModeInHeader( _
        genericC.header, GenericStringOverrideModeInPolicy(genericC.policy, sourceName), _
        freeBasicType)
End Function

Private Function ApplyGenericStringOverrideModeInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal overrideMode As Long, ByVal freeBasicType As String _
) As String
    If overrideMode = 0 OrElse freeBasicType = "" Then Return freeBasicType

    Dim typePrefix As String
    Dim typeSuffix As String
    Dim typeForMapping As String = freeBasicType
    If Left(typeForMapping, 6) = "Const " Then
        typePrefix = "Const "
        typeForMapping = Mid(typeForMapping, 7)
    End If
    While Right(typeForMapping, 4) = " Ptr"
        typeSuffix &= " Ptr"
        typeForMapping = RTrim(Left(typeForMapping, Len(typeForMapping) - 4))
    Wend
    Dim storageType As String = _
        GenericHeaderTypeAliasStorageTypeInHeader(headerState, typeForMapping, 0)
    If storageType <> "" Then
        typeForMapping = storageType & typeSuffix
    Else
        typeForMapping &= typeSuffix
    End If
    If typePrefix <> "" Then typeForMapping = typePrefix & typeForMapping

    ' Resolve aliases before choosing a string representation. A typedef can
    ' add pointer levels around wchar_t or byte, so count those after expansion.
    typePrefix = ""
    If Left(typeForMapping, 6) = "Const " Then
        typePrefix = "Const "
        typeForMapping = Mid(typeForMapping, 7)
    End If
    typeSuffix = ""
    Dim pointerCount As Long = 0
    While Right(typeForMapping, 4) = " Ptr"
        pointerCount += 1
        typeSuffix &= " Ptr"
        typeForMapping = RTrim(Left(typeForMapping, Len(typeForMapping) - 4))
    Wend

    If overrideMode < 0 Then
        If typeForMapping = "ZString" Then
            typeForMapping = "Byte"
        ElseIf typeForMapping = "WString" Then
            typeForMapping = "wchar_t"
        End If
    ElseIf pointerCount > 0 Then
        If typeForMapping = "Byte" OrElse typeForMapping = "UByte" Then
            typeForMapping = "ZString"
        ElseIf typeForMapping = "wchar_t" Then
            typeForMapping = "WString"
        End If
    End If
    Dim resultType As String = typePrefix & typeForMapping & typeSuffix
    While Left(resultType, Len("Const Const ")) = "Const Const "
        resultType = "Const " & Mid(resultType, Len("Const Const ") + 1)
    Wend
    Return resultType
End Function

Private Function GenericFixedStringTypeInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal elementType As String, ByVal elementCount As Long _
) As String
    If elementCount <= 0 Then Return ""
    Dim qualifier As String
    elementType = GenericStringElementTypeInHeader(headerState, elementType, qualifier)
    If elementType = "" Then Return ""
    Dim stringType As String
    Select Case elementType
    Case "Byte", "UByte"
        stringType = "ZString"
    Case "wchar_t"
        stringType = "WString"
    Case "ZString"
        stringType = "ZString"
    Case "WString"
        stringType = "WString"
    Case Else
        Return ""
    End Select
    Return qualifier & stringType & " * " & Trim(Str(elementCount))
End Function

Private Function GenericStringPointerTypeInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal elementType As String _
) As String
    Dim qualifier As String
    elementType = GenericStringElementTypeInHeader(headerState, elementType, qualifier)
    If elementType = "" Then Return ""
    Dim stringType As String
    Select Case elementType
    Case "Byte", "UByte"
        stringType = "ZString"
    Case "wchar_t"
        stringType = "WString"
    Case "ZString"
        stringType = "ZString"
    Case "WString"
        stringType = "WString"
    Case Else
        Return ""
    End Select
    Return qualifier & stringType & " Ptr"
End Function

Private Function GenericStringElementTypeInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal freeBasicType As String, ByRef qualifier As String _
) As String
    qualifier = ""
    Dim elementType As String = Trim(freeBasicType)
    If Left(elementType, 6) = "Const " Then
        qualifier = "Const "
        elementType = Mid(elementType, 7)
    End If
    If InStr(elementType, " Ptr") > 0 OrElse InStr(elementType, " * ") > 0 Then _
        Return ""

    Dim storageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        headerState, elementType, 0)
    If storageType <> "" Then elementType = storageType
    If Left(elementType, 6) = "Const " Then
        qualifier = "Const "
        elementType = Mid(elementType, 7)
    End If
    If InStr(elementType, " Ptr") > 0 OrElse InStr(elementType, " * ") > 0 Then _
        Return ""
    Return elementType
End Function

Private Function GenericHeaderFbfrogStringTypedefTypeInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal freeBasicType As String _
) As String
    Dim pointerType As String = ApplyGenericStringOverrideModeInHeader( _
        headerState, 1, freeBasicType & " Ptr")
    If Right(pointerType, 4) <> " Ptr" Then Return freeBasicType
    Return Left(pointerType, Len(pointerType) - 4)
End Function

Private Function GenericHeaderFbfrogWStringWidthMatches( _
    ByRef translation As C2fbTranslationContext _
) As Long
    Dim cWStringSize As Long = GenericHeaderPreprocessorSizeValue( _
        translation, "__SIZEOF_WCHAR_T__")
    If cWStringSize <= 0 Then Return 0
    Dim fbWStringSize As Long = translation.genericC.policy.fbfrogWStringSize
    If fbWStringSize <= 0 Then fbWStringSize = SizeOf(WString)
    Return CInt(cWStringSize = fbWStringSize) * -1
End Function

Private Function GenericHeaderCCharacterKindInType( _
    ByRef translation As C2fbTranslationContext, ByVal sourceType As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(Trim(sourceType), tokens(), tokenCount)
    If tokenCount <= 0 Then Return C2FB_C_CHARACTER_NONE
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel(tokens(), 0, tokenCount - 1, parsedType) = 0 Then _
        Return C2FB_C_CHARACTER_NONE
    Select Case parsedType.baseName
    Case "char": Return C2FB_C_CHARACTER_CHAR
    Case "signed char": Return C2FB_C_CHARACTER_SIGNED
    Case "unsigned char": Return C2FB_C_CHARACTER_UNSIGNED
    Case "wchar_t": Return C2FB_C_CHARACTER_WIDE
    End Select
    Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, parsedType.baseName, 0)
    If aliasIndex >= 0 Then _
        Return translation.genericC.header.headerTypeAliases(aliasIndex).characterKind
    Return C2FB_C_CHARACTER_NONE
End Function

Private Function GenericHeaderFbfrogStringDefaultMode( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByVal freeBasicType As String = "" _
) As Long
    sourceType = Trim(sourceType)
    If sourceType <> "" Then
        Dim tokens() As String
        Dim tokenCount As Long
        TokenizeCDeclaration(sourceType, tokens(), tokenCount)
        If tokenCount > 0 Then
            Dim parsedType As C2fbCTypeModel
            If ParseCTypeModel(tokens(), 0, tokenCount - 1, parsedType) <> 0 Then
                Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
                    translation.genericC.header, parsedType.baseName, 0)
                If aliasIndex >= 0 Then
                    Dim explicitMode As Long = GenericStringOverrideModeInPolicy( _
                        translation.genericC.policy, parsedType.baseName)
                    If explicitMode <> 0 Then Return explicitMode
                End If
                Dim mappedType As String = Trim(freeBasicType)
                If Left(mappedType, 6) = "Const " Then mappedType = Mid(mappedType, 7)
                Dim mappedPointerDepth As Long = 0
                While Right(mappedType, 4) = " Ptr"
                    mappedType = Left(mappedType, Len(mappedType) - 4)
                    mappedPointerDepth += 1
                Wend
                Dim mappedStorageType As String = _
                    GenericHeaderTypeAliasStorageTypeInHeader( _
                        translation.genericC.header, mappedType, 0)
                If mappedStorageType <> "" Then mappedType = mappedStorageType
                If Left(mappedType, 6) = "Const " Then mappedType = Mid(mappedType, 7)
                While Right(mappedType, 4) = " Ptr"
                    mappedType = Left(mappedType, Len(mappedType) - 4)
                    mappedPointerDepth += 1
                Wend
                If mappedPointerDepth > 0 AndAlso _
                   (mappedType = "ZString" OrElse mappedType = "WString") Then Return 0
                If translation.genericC.policy.fbfrogStringDefaults <> 0 Then
                    Select Case GenericHeaderCCharacterKindInType( _
                        translation, sourceType)
                    Case C2FB_C_CHARACTER_CHAR
                        Return 1
                    Case C2FB_C_CHARACTER_WIDE
                        If GenericHeaderFbfrogWStringWidthMatches(translation) <> 0 Then _
                            Return 1
                    End Select
                End If
            End If
        End If
    End If

    Dim resolvedType As String = Trim(freeBasicType)
    If Left(resolvedType, 6) = "Const " Then resolvedType = Mid(resolvedType, 7)
    While Right(resolvedType, 4) = " Ptr"
        resolvedType = Left(resolvedType, Len(resolvedType) - 4)
    Wend
    Dim storageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, resolvedType, 0)
    If storageType <> "" Then resolvedType = storageType
    If Left(resolvedType, 6) = "Const " Then resolvedType = Mid(resolvedType, 7)
    If resolvedType = "ZString" Then Return 1
    If resolvedType = "WString" AndAlso _
       GenericHeaderFbfrogWStringWidthMatches(translation) <> 0 Then Return 1
    If resolvedType = "wchar_t" AndAlso _
       translation.genericC.policy.fbfrogStringDefaults <> 0 AndAlso _
       GenericHeaderFbfrogWStringWidthMatches(translation) <> 0 Then Return 1
    Return 0
End Function

Private Function GenericHeaderFbfrogCharacterScalarType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByVal freeBasicType As String _
) As String
    Dim characterKind As Long = GenericHeaderCCharacterKindInType( _
        translation, sourceType)
    If characterKind = C2FB_C_CHARACTER_NONE Then Return ""

    Dim isConst As Long = 0
    Dim sourceStorageType As String = Trim(freeBasicType)
    If Left(sourceStorageType, 6) = "Const " Then
        isConst = -1
        sourceStorageType = Mid(sourceStorageType, 7)
    End If
    Dim aliasStorageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, sourceStorageType, 0)
    If aliasStorageType <> "" Then sourceStorageType = aliasStorageType
    If Left(sourceStorageType, 6) = "Const " Then
        isConst = -1
        sourceStorageType = Mid(sourceStorageType, 7)
    End If

    Dim result As String
    Select Case characterKind
    Case C2FB_C_CHARACTER_CHAR, C2FB_C_CHARACTER_SIGNED
        result = "Byte"
    Case C2FB_C_CHARACTER_UNSIGNED
        result = "UByte"
    Case C2FB_C_CHARACTER_WIDE
        result = "wchar_t"
    Case Else
        Return ""
    End Select
    If isConst <> 0 Then result = "Const " & result
    Return result
End Function

Private Function GenericHeaderFbfrogStringArrayShape( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal elementType As String, ByVal arrayBounds As String, _
    ByVal totalElementCount As Long, ByRef fixedStringType As String, _
    ByRef outerBounds As String, ByRef outerElementCount As Long _
) As Long
    fixedStringType = ""
    outerBounds = ""
    outerElementCount = 0
    If arrayBounds = "" OrElse totalElementCount <= 0 Then Return 0

    Dim lastSeparator As Long = InStrRev(arrayBounds, ",")
    Dim lastDimension As String = Trim(Mid(arrayBounds, lastSeparator + 1))
    Dim toPosition As Long = InStr(lastDimension, " To ")
    If toPosition = 0 Then Return 0
    Dim lowerBound As Long
    Dim upperBound As Long
    If EvaluateSimpleArrayBound( _
        Trim(Left(lastDimension, toPosition - 1)), lowerBound, _
        MAX_GENERIC_ARRAY_COUNT, -1) = 0 OrElse _
       EvaluateSimpleArrayBound( _
        Trim(Mid(lastDimension, toPosition + Len(" To "))), upperBound, _
        MAX_GENERIC_ARRAY_COUNT) = 0 OrElse upperBound < lowerBound Then Return 0

    Dim lastDimensionCount As Long = upperBound - lowerBound + 1
    If lastDimensionCount <= 0 OrElse _
       totalElementCount Mod lastDimensionCount <> 0 Then Return 0
    fixedStringType = GenericFixedStringTypeInHeader( _
        headerState, elementType, lastDimensionCount)
    If fixedStringType = "" Then Return 0

    If lastSeparator > 0 Then outerBounds = Trim(Left(arrayBounds, lastSeparator - 1))
    outerElementCount = totalElementCount \ lastDimensionCount
    If outerBounds = "" Then outerElementCount = 1
    Return -1
End Function

Private Function GenericHeaderFunctionAliasTypeInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal aliasIndex As Long, ByVal depth As Long = 0 _
) As String
    If aliasIndex < 0 OrElse aliasIndex >= headerState.headerTypeAliasCount OrElse _
       depth >= 32 OrElse headerState.headerTypeAliases(aliasIndex).isFunction = 0 Then Return ""
    Dim baseType As String = headerState.headerTypeAliases(aliasIndex).baseType
    If Left(baseType, 9) = "Function " OrElse Left(baseType, 4) = "Sub " Then Return baseType
    For candidateIndex As Long = 0 To headerState.headerTypeAliasCount - 1
        If headerState.headerTypeAliases(candidateIndex).freeBasicName = baseType Then _
            Return GenericHeaderFunctionAliasTypeInHeader( _
                headerState, candidateIndex, depth + 1)
    Next
    Return ""
End Function

Private Sub RecordGenericHeaderTypeAliasInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal sourceName As String, ByVal freeBasicName As String, _
    ByVal baseType As String = "", ByVal emitted As Long = 0, _
    ByVal isTag As Long = 0, ByVal isArray As Long = 0, _
    ByVal arrayCount As Long = 0, ByVal arrayElementType As String = "", _
    ByVal isFunction As Long = 0, ByVal isForward As Long = 0, _
    ByVal arrayBounds As String = "", ByVal characterKind As Long = _
        C2FB_C_CHARACTER_NONE, ByVal functionPointerDepth As Long = 0, _
    ByVal alignmentValue As Long = 0 _
)
    If sourceName = "" OrElse freeBasicName = "" Then Exit Sub
    If GenericHeaderTypeAliasIndexInHeader( _
        headerState, sourceName, isTag) >= 0 Then Exit Sub
    If headerState.headerTypeAliasCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
        ReportError("generic header exceeds the configured typedef limit")
    If headerState.headerTypeAliasCount > UBound(headerState.headerTypeAliases) Then _
        ReDim Preserve headerState.headerTypeAliases(0 To UBound(headerState.headerTypeAliases) * 2 + 1)
    With headerState.headerTypeAliases(headerState.headerTypeAliasCount)
        .sourceName = sourceName
        .freeBasicName = freeBasicName
        .baseType = baseType
        .characterKind = characterKind
        .arrayElementType = arrayElementType
        .arrayCount = arrayCount
        .arrayBounds = arrayBounds
        .emitted = emitted
        .isTag = isTag
        .isArray = isArray
        .isFunction = isFunction
        .isForward = isForward
        .functionPointerDepth = functionPointerDepth
        .alignmentValue = alignmentValue
    End With
    Dim indexKey As String = IIf(isTag <> 0, "T", "I") & sourceName
    If AddC2fbStringIndexMapEntry( _
        headerState.typeAliasIndex, indexKey, _
        headerState.headerTypeAliasCount) <> -1 Then _
        ReportError("generic header type-alias index exceeds its configured limit")
    Dim freeBasicKey As String = LCase(freeBasicName)
    If GenericHeaderTypeAliasIndexByFreeBasicNameInHeader( _
        headerState, freeBasicName) < 0 AndAlso _
       AddC2fbStringIndexMapEntry( _
        headerState.freeBasicTypeAliasIndex, freeBasicKey, _
        headerState.headerTypeAliasCount) = 0 Then _
        ReportError("generic header FreeBASIC type-alias index exceeds its configured limit")
    headerState.headerTypeAliasCount += 1
End Sub

Private Sub MarkGenericHeaderTypeAliasEmittedInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal sourceName As String, ByVal isTag As Long = 0 _
)
    Dim index As Long = GenericHeaderTypeAliasIndexInHeader( _
        headerState, sourceName, isTag)
    If index >= 0 Then headerState.headerTypeAliases(index).emitted = -1
End Sub

Private Sub RemoveGenericHeaderTypeAliasInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal sourceName As String, ByVal depth As Long = 0, _
    ByVal isTag As Long = 0 _
)
    If depth >= 32 Then Exit Sub
    Dim index As Long = GenericHeaderTypeAliasIndexInHeader( _
        headerState, sourceName, isTag)
    If index < 0 Then Exit Sub
    Dim freeBasicName As String = headerState.headerTypeAliases(index).freeBasicName
    Dim aliasIndex As Long = headerState.headerTypeAliasCount - 1
    While aliasIndex >= 0
        If headerState.headerTypeAliases(aliasIndex).baseType = freeBasicName Then
            RemoveGenericHeaderTypeAliasInHeader( _
                headerState, headerState.headerTypeAliases(aliasIndex).sourceName, _
                depth + 1, headerState.headerTypeAliases(aliasIndex).isTag)
            aliasIndex = headerState.headerTypeAliasCount
        End If
        aliasIndex -= 1
    Wend
    For moveIndex As Long = index To headerState.headerTypeAliasCount - 2
        headerState.headerTypeAliases(moveIndex) = headerState.headerTypeAliases(moveIndex + 1)
    Next
    headerState.headerTypeAliasCount -= 1
    RebuildGenericHeaderTypeAliasIndex(headerState)
End Sub

/' end of c2fb_generic_header_state.bi '/
