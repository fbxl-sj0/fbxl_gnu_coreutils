/'
    Project: C2FB generic C type-size expressions
    ---------------------------------------------

    File: c2fb_generic_sizeof.bi

    Purpose:

        Resolve sizeof, scalar alignof, and supported offsetof terms used in
        generic C integer constant expressions, using the active C target ABI.

    Responsibilities:

        - Read scalar and pointer widths from predefined C ABI macros.
        - Resolve typedef storage through the generic-header type model.
        - Resolve sizeof terms for modeled scalar and simple aggregate types.
        - Resolve scalar and pointer alignment terms in the target ABI.
        - Resolve direct members in simple C record layouts.
        - Resolve fixed-array member sizes from prepared generic record layouts.
        - Replace sizeof terms in array bounds only when their size is known.
        - Keep integer casts only when they preserve the resolved size value.

    This file intentionally does NOT contain:

        - Complete C aggregate layout-size calculation.
        - Runtime sizeof expression lowering for function bodies.
'/

Private Function GenericHeaderPreprocessorSizeValue( _
    ByRef translation As C2fbTranslationContext, ByVal macroName As String _
) As Long
    For macroIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse .definition.sourceName <> macroName Then _
                Continue For
            Dim byteCount As Long
            If EvaluateSimpleArrayBound( _
                Trim(.definition.rawValue), byteCount, 16) <> 0 Then _
                Return byteCount
            Return 0
        End With
    Next
    Return 0
End Function

Private Function GenericHeaderFreeBasicScalarSize( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicType As String _
) As Long
    If Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Mid(freeBasicType, 7)
    Dim storedType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, freeBasicType, 0)
    If storedType <> "" Then freeBasicType = storedType
    If Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Mid(freeBasicType, 7)

    Dim lowerTypeName As String = LCase(freeBasicType)
    Dim fixedStringPrefix As String
    Dim stringElementSize As Long = 0
    If Left(lowerTypeName, Len("zstring * ")) = "zstring * " Then
        fixedStringPrefix = "zstring * "
        stringElementSize = 1
    ElseIf Left(lowerTypeName, Len("wstring * ")) = "wstring * " Then
        fixedStringPrefix = "wstring * "
        stringElementSize = GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_WCHAR_T__")
    End If
    If fixedStringPrefix <> "" Then
        Dim characterCount As Long
        If stringElementSize <= 0 OrElse EvaluateSimpleArrayBound( _
            Trim(Mid(lowerTypeName, Len(fixedStringPrefix) + 1)), _
            characterCount, MAX_GENERIC_ARRAY_COUNT) = 0 OrElse _
           characterCount <= 0 OrElse _
           characterCount > MAX_GENERIC_ARRAY_COUNT \ stringElementSize Then _
            Return 0
        Return characterCount * stringElementSize
    End If

    Select Case LCase(freeBasicType)
    Case "byte", "ubyte", "boolean": Return 1
    Case "short", "ushort": Return 2
    Case "long", "ulong", "c2fb_c_int", "c2fb_c_uint": Return 4
    Case "longint", "ulongint", "c2fb_int64", "c2fb_uint64": Return 8
    Case "integer", "uinteger", "c2fb_size_t"
        Return GenericHeaderPreprocessorSizeValue(translation, "__SIZEOF_POINTER__")
    Case "clong", "culong", "c2fb_c_long", "c2fb_c_ulong"
        Dim longSize As Long = _
            GenericHeaderPreprocessorSizeValue(translation, "__SIZEOF_LONG__")
        If longSize > 0 Then Return longSize
        If translation.genericC.policy.cLong32 <> 0 Then Return 4
        Return 0
    Case "single": Return 4
    Case "double": Return 8
    Case "__bf16", "_float16": Return 2
    Case "zstring": Return 1
    Case "wstring"
        Return GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_WCHAR_T__")
    Case "clongdouble"
        Return GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_LONG_DOUBLE__")
    End Select
    Return 0
End Function

Private Function GenericHeaderCLongDoubleAlignmentBytes( _
    ByRef translation As C2fbTranslationContext _
) As Long
    Dim longDoubleSize As Long = GenericHeaderPreprocessorSizeValue( _
        translation, "__SIZEOF_LONG_DOUBLE__")
    Dim pointerSize As Long = GenericHeaderPreprocessorSizeValue( _
        translation, "__SIZEOF_POINTER__")

    Select Case longDoubleSize
    Case 16
        ' The x86-64 C ABI aligns its 16-byte long double to 16 bytes.
        If pointerSize = 8 AndAlso _
           GenericHeaderPreprocessorSizeValue(translation, "__x86_64__") <> 0 Then _
            Return 16
    Case 8
        ' On 64-bit targets where long double is double-sized, its alignment
        ' matches the native 64-bit integer carrier used by FreeBASIC.
        If pointerSize = 8 Then Return 8
    Case 12
        ' The x86 32-bit ABI stores the extended value in 12 bytes and aligns
        ' it to the four-byte word boundary.
        If pointerSize = 4 AndAlso _
           GenericHeaderPreprocessorSizeValue(translation, "__i386__") <> 0 Then _
            Return 4
    End Select
    Return 0
End Function

Private Function GenericHeaderFreeBasicScalarAlignment( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicType As String, ByVal scalarSize As Long _
) As Long
    If Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Mid(freeBasicType, 7)
    Dim storedType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, freeBasicType, 0)
    If storedType <> "" Then freeBasicType = storedType

    Select Case LCase(freeBasicType)
    Case "byte", "ubyte", "boolean", "zstring", "wstring"
        Return 1
    Case "short", "ushort"
        Return 2
    Case "long", "ulong", "single"
        Return 4
    Case "clong", "culong", "c2fb_c_long", "c2fb_c_ulong"
        Return GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_LONG__")
    Case "integer", "uinteger", "c2fb_size_t"
        Return GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_POINTER__")
    Case "longint", "ulongint", "double", "c2fb_int64", "c2fb_uint64"
        Dim pointerSize As Long = GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_POINTER__")
        If pointerSize >= 8 Then Return 8
        ' MinGW's 32-bit x86 ABI aligns 64-bit scalars to eight bytes even
        ' though its pointers and C long values are four bytes.
        If pointerSize = 4 AndAlso _
           GenericHeaderPreprocessorSizeValue(translation, "__i386__") <> 0 AndAlso _
           GenericHeaderPreprocessorSizeValue(translation, "__MINGW32__") <> 0 Then _
            Return 8
        Return 0
    Case "clongdouble"
        Return GenericHeaderCLongDoubleAlignmentBytes(translation)
    End Select
    If scalarSize > 0 AndAlso scalarSize <= 4 Then Return scalarSize
    Return 0
End Function

Private Function GenericHeaderSimpleRecordSizeInBytes( _
    ByRef translation As C2fbTranslationContext, ByVal freeBasicType As String _
) As Long
    Dim storageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, freeBasicType, 0)
    If storageType <> "" AndAlso LCase(storageType) <> "record" Then _
        freeBasicType = storageType
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        If declarationIndex >= _
           translation.genericC.header.recordPlanCount Then Continue For
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) Then Continue For
            If translation.genericC.header.recordPlans( _
                declarationIndex).isPrepared = 0 OrElse _
               translation.genericC.header.recordPlans( _
                declarationIndex).isSupported = 0 OrElse _
               translation.genericC.header.recordPlans( _
                declarationIndex).bindingReady = 0 OrElse _
               translation.genericC.header.recordPlans( _
                declarationIndex).binding.isPacked <> 0 OrElse _
               translation.genericC.header.recordPlans( _
                declarationIndex).binding.packValue <> 0 OrElse _
               translation.genericC.header.recordPlans( _
                declarationIndex).binding.alignmentValue <> 0 OrElse _
               translation.genericC.header.recordPlans( _
                declarationIndex).hasNonByteFlexibleTail <> 0 Then Continue For
            If translation.genericC.header.recordPlans( _
                declarationIndex).freeBasicName <> freeBasicType AndAlso _
               translation.genericC.header.recordPlans( _
                declarationIndex).aliasFreeBasicName <> freeBasicType AndAlso _
               translation.genericC.header.recordPlans( _
                declarationIndex).implementationName <> freeBasicType Then _
                Continue For
            Dim offset As Long = 0
            Dim unionSize As Long = 0
            Dim maximumAlignment As Long = 1
            For itemIndex As Long = 0 To _
                translation.genericC.header.recordPlans( _
                    declarationIndex).binding.itemCount - 1
                With translation.genericC.header.recordPlans( _
                    declarationIndex).binding.items(itemIndex)
                    If .kind <> C2FB_RECORD_BINDING_ITEM_FIELD OrElse _
                       .isBitField <> 0 OrElse .zeroArrayAccessorName <> "" OrElse _
                       .arrayCount < 0 OrElse .packValue <> 0 Then Return 0
                    Dim fieldType As String = .fieldType
                    Dim fieldPointerDepth As Long = 0
                    While Right(LCase(fieldType), 4) = " ptr"
                        fieldType = Trim(Left(fieldType, Len(fieldType) - 4))
                        fieldPointerDepth += 1
                    Wend
                    Dim fieldSize As Long
                    Dim fieldAlignment As Long
                    If fieldPointerDepth > 0 Then
                        fieldSize = GenericHeaderPreprocessorSizeValue( _
                            translation, "__SIZEOF_POINTER__")
                        fieldAlignment = fieldSize
                    Else
                        fieldSize = GenericHeaderFreeBasicScalarSize( _
                            translation, fieldType)
                        fieldAlignment = GenericHeaderFreeBasicScalarAlignment( _
                            translation, fieldType, fieldSize)
                    End If
                    If fieldSize <= 0 OrElse fieldAlignment <= 0 Then Return 0
                    If .arrayCount > 0 Then
                        If fieldSize > MAX_GENERIC_ARRAY_BOUND_VALUE \ .arrayCount Then _
                            Return 0
                        fieldSize *= .arrayCount
                    End If
                    If fieldAlignment > maximumAlignment Then _
                        maximumAlignment = fieldAlignment

                    If translation.genericC.header.recordPlans( _
                        declarationIndex).binding.isUnion <> 0 Then
                        If fieldSize > unionSize Then unionSize = fieldSize
                    Else
                        Dim remainder As Long = offset Mod fieldAlignment
                        If remainder <> 0 Then
                            Dim padding As Long = fieldAlignment - remainder
                            If offset > MAX_GENERIC_ARRAY_BOUND_VALUE - padding Then _
                                Return 0
                            offset += padding
                        End If
                        If fieldSize > MAX_GENERIC_ARRAY_BOUND_VALUE - offset Then _
                            Return 0
                        offset += fieldSize
                    End If
                End With
            Next

            If translation.genericC.header.recordPlans( _
                declarationIndex).binding.isUnion <> 0 Then offset = unionSize
            Dim remainder As Long = offset Mod maximumAlignment
            If remainder <> 0 Then
                Dim padding As Long = maximumAlignment - remainder
                If offset > MAX_GENERIC_ARRAY_BOUND_VALUE - padding Then Return 0
                offset += padding
            End If
            Return offset
        End With
    Next

    ' Generic body record bindings can be the only available C field layout
    ' when the body pass reuses a port-owned FreeBASIC record.
    For bodyRecordIndex As Long = 0 To _
        translation.body.recordBindingCount - 1
        With translation.body.recordBindings(bodyRecordIndex)
            If (.fbName <> freeBasicType AndAlso _
                .sourceName <> freeBasicType AndAlso _
                .staticInitializerBinding.freeBasicName <> freeBasicType) OrElse _
               .staticInitializerBinding.itemCount <= 0 Then Continue For
            With .staticInitializerBinding
                If .isPacked <> 0 OrElse .packValue <> 0 OrElse _
                   .alignmentValue <> 0 Then Return 0
                Dim recordIsUnion As Long = .isUnion
                Dim offset As Long = 0
                Dim unionSize As Long = 0
                Dim maximumAlignment As Long = 1
                For itemIndex As Long = 0 To .itemCount - 1
                    With .items(itemIndex)
                        If .kind <> C2FB_RECORD_BINDING_ITEM_FIELD OrElse _
                           .isBitField <> 0 OrElse .packValue <> 0 OrElse _
                           .arrayCount < 0 Then Return 0
                        Dim fieldType As String = .fieldType
                        Dim fieldPointerDepth As Long = 0
                        While Right(LCase(fieldType), 4) = " ptr"
                            fieldType = Trim(Left( _
                                fieldType, Len(fieldType) - 4))
                            fieldPointerDepth += 1
                        Wend
                        Dim fieldSize As Long
                        Dim fieldAlignment As Long
                        If fieldPointerDepth > 0 Then
                            fieldSize = GenericHeaderPreprocessorSizeValue( _
                                translation, "__SIZEOF_POINTER__")
                            fieldAlignment = fieldSize
                        Else
                            fieldSize = GenericHeaderFreeBasicScalarSize( _
                                translation, fieldType)
                            fieldAlignment = GenericHeaderFreeBasicScalarAlignment( _
                                translation, fieldType, fieldSize)
                        End If
                        If fieldSize <= 0 OrElse fieldAlignment <= 0 Then Return 0
                        If .arrayCount > 0 Then
                            If fieldSize > _
                               MAX_GENERIC_ARRAY_BOUND_VALUE \.arrayCount Then _
                                Return 0
                            fieldSize *= .arrayCount
                        End If
                        If fieldAlignment > maximumAlignment Then _
                            maximumAlignment = fieldAlignment

                        If recordIsUnion <> 0 Then
                            If fieldSize > unionSize Then unionSize = fieldSize
                        Else
                            Dim remainder As Long = offset Mod fieldAlignment
                            If remainder <> 0 Then
                                Dim padding As Long = fieldAlignment - remainder
                                If offset > _
                                   MAX_GENERIC_ARRAY_BOUND_VALUE - padding Then _
                                    Return 0
                                offset += padding
                            End If
                            If fieldSize > _
                               MAX_GENERIC_ARRAY_BOUND_VALUE - offset Then _
                                Return 0
                            offset += fieldSize
                        End If
                    End With
                Next

                If recordIsUnion <> 0 Then offset = unionSize
                Dim remainder As Long = offset Mod maximumAlignment
                If remainder <> 0 Then
                    Dim padding As Long = maximumAlignment - remainder
                    If offset > MAX_GENERIC_ARRAY_BOUND_VALUE - padding Then _
                        Return 0
                    offset += padding
                End If
                Return offset
            End With
        End With
    Next
    Return 0
End Function

Private Function GenericHeaderRecordArrayMemberSizeInBytes( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicRecordType As String, ByVal sourceField As String _
) As Long
    If IsIdentifierToken(sourceField) = 0 Then Return 0
    If Left(freeBasicRecordType, 6) = "Const " Then _
        freeBasicRecordType = Mid(freeBasicRecordType, 7)

    Dim matchingPlan As Long = -1
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        If declarationIndex >= _
           translation.genericC.header.recordPlanCount Then Continue For
        With translation.genericC.header.recordPlans(declarationIndex)
            ' Overall alignment rounds record size but does not move fields.
            If .isPrepared = 0 OrElse .isSupported = 0 OrElse _
               .bindingReady = 0 Then Continue For
            If .freeBasicName <> freeBasicRecordType AndAlso _
               .aliasFreeBasicName <> freeBasicRecordType AndAlso _
               .implementationName <> freeBasicRecordType Then Continue For
            If matchingPlan >= 0 Then Return 0
            matchingPlan = declarationIndex
        End With
    Next
    If matchingPlan < 0 Then Return 0

    Dim recordPlan As C2fbGenericRecordPlanModel = _
        translation.genericC.header.recordPlans(matchingPlan)
    For itemIndex As Long = 0 To recordPlan.binding.itemCount - 1
        With recordPlan.binding.items(itemIndex)
            If .kind <> C2FB_RECORD_BINDING_ITEM_FIELD OrElse _
               .sourceName <> sourceField OrElse .arrayCount <= 0 Then _
                Continue For

            Dim fieldType As String = .fieldType
            Dim fieldPointerDepth As Long = 0
            While Right(LCase(fieldType), 4) = " ptr"
                fieldType = Trim(Left(fieldType, Len(fieldType) - 4))
                fieldPointerDepth += 1
            Wend

            Dim elementSize As Long
            If fieldPointerDepth > 0 Then
                elementSize = GenericHeaderPreprocessorSizeValue( _
                    translation, "__SIZEOF_POINTER__")
            Else
                elementSize = GenericHeaderFreeBasicScalarSize( _
                    translation, fieldType)
                If elementSize <= 0 Then _
                    elementSize = GenericHeaderSimpleRecordSizeInBytes( _
                        translation, fieldType)
            End If
            If elementSize <= 0 OrElse _
               .arrayCount > MAX_GENERIC_ARRAY_BOUND_VALUE \ elementSize Then _
                Return 0
            Return elementSize * .arrayCount
        End With
    Next
    Return 0
End Function

Private Function GenericHeaderSizeofTypeInBytes( _
    ByRef translation As C2fbTranslationContext, ByVal sourceType As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceType, tokens(), tokenCount)
    If tokenCount = 0 OrElse tokenCount >= MAX_TYPE_WORDS Then Return 0
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel(tokens(), 0, tokenCount - 1, parsedType) = 0 OrElse _
       parsedType.hasUnsupportedSyntax <> 0 Then Return 0

    Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, parsedType.baseName, 0)
    If parsedType.pointerDepth = 0 AndAlso aliasIndex >= 0 Then
        With translation.genericC.header.headerTypeAliases(aliasIndex)
            If .isArray <> 0 Then
                If .arrayCount <= 0 Then Return 0
                Dim elementSize As Long = GenericHeaderFreeBasicScalarSize( _
                    translation, .arrayElementType)
                If elementSize <= 0 OrElse _
                   elementSize > MAX_GENERIC_ARRAY_BOUND_VALUE \ .arrayCount Then _
                    Return 0
                Return elementSize * .arrayCount
            End If
        End With
    End If

    Dim pointerCount As Long = 0
    Dim isConst As Long = 0
    Dim freeBasicType As String = MapGenericHeaderCType( _
        translation, parsedType, pointerCount, isConst, _
        C2FB_POINTER_MAPPING_PRESERVE)
    If freeBasicType = "" Then Return 0
    Dim freeBasicPointerDepth As Long = _
        GenericFreeBasicTypePointerDepthInHeader( _
            translation.genericC.header, freeBasicType, 0)
    If pointerCount > 0 OrElse freeBasicPointerDepth > 0 OrElse _
       InStr(freeBasicType, " Ptr") <> 0 Then _
        Return GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_POINTER__")
    If parsedType.isStruct <> 0 OrElse parsedType.isUnion <> 0 Then _
        Return GenericHeaderSimpleRecordSizeInBytes( _
            translation, freeBasicType)
    Dim scalarSize As Long = GenericHeaderFreeBasicScalarSize( _
        translation, freeBasicType)
    If scalarSize > 0 Then Return scalarSize
    Return GenericHeaderSimpleRecordSizeInBytes(translation, freeBasicType)
End Function

Private Function GenericHeaderRecordFieldOffsetInBytes( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByVal sourceField As String _
) As Long
    If IsIdentifierToken(sourceField) = 0 Then Return -1
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceType, tokens(), tokenCount)
    If tokenCount = 0 OrElse tokenCount >= MAX_TYPE_WORDS Then Return -1
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel(tokens(), 0, tokenCount - 1, parsedType) = 0 OrElse _
       parsedType.hasUnsupportedSyntax <> 0 OrElse parsedType.pointerDepth <> 0 Then _
        Return -1

    Dim pointerCount As Long = 0
    Dim isConst As Long = 0
    Dim freeBasicType As String = MapGenericHeaderCType( _
        translation, parsedType, pointerCount, isConst, _
        C2FB_POINTER_MAPPING_PRESERVE)
    If freeBasicType = "" OrElse pointerCount <> 0 Then Return -1
    Dim matchingPlan As Long = -1
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        If declarationIndex >= _
           translation.genericC.header.recordPlanCount Then Continue For
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) Then Continue For
        End With
        With translation.genericC.header.recordPlans(declarationIndex)
            If .isPrepared = 0 OrElse .isSupported = 0 OrElse _
               .bindingReady = 0 OrElse .binding.isPacked <> 0 OrElse _
               .binding.packValue <> 0 OrElse _
               .hasNonByteFlexibleTail <> 0 Then Continue For
            If .freeBasicName <> freeBasicType AndAlso _
               .aliasFreeBasicName <> freeBasicType AndAlso _
               .implementationName <> freeBasicType Then Continue For
            If matchingPlan >= 0 Then Return -1
            matchingPlan = declarationIndex
        End With
    Next
    If matchingPlan < 0 Then Return -1

    Dim recordPlan As C2fbGenericRecordPlanModel = _
        translation.genericC.header.recordPlans(matchingPlan)
    Dim isUnion As Long = recordPlan.binding.isUnion
    Dim offset As Long = 0
    For itemIndex As Long = 0 To recordPlan.binding.itemCount - 1
        With recordPlan.binding.items(itemIndex)
            If (.kind <> C2FB_RECORD_BINDING_ITEM_FIELD AndAlso _
                .kind <> C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY) OrElse _
               .isBitField <> 0 OrElse .packValue <> 0 OrElse _
               .arrayCount < 0 Then Return -1
            Dim fieldType As String = .fieldType
            Dim fieldPointerDepth As Long = 0
            While Right(LCase(fieldType), 4) = " ptr"
                fieldType = Trim(Left(fieldType, Len(fieldType) - 4))
                fieldPointerDepth += 1
            Wend
            Dim fieldSize As Long
            Dim fieldAlignment As Long
            If fieldPointerDepth > 0 Then
                fieldSize = GenericHeaderPreprocessorSizeValue( _
                    translation, "__SIZEOF_POINTER__")
                fieldAlignment = fieldSize
            Else
                fieldSize = GenericHeaderFreeBasicScalarSize( _
                    translation, fieldType)
                If fieldSize <= 0 Then fieldSize = _
                    GenericHeaderSimpleRecordSizeInBytes(translation, fieldType)
                fieldAlignment = GenericHeaderFreeBasicScalarAlignment( _
                    translation, fieldType, fieldSize)
            End If
            If fieldSize < 0 OrElse fieldAlignment <= 0 Then Return -1
            Dim elementCount As Long = .arrayCount
            If .kind = C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY Then
                elementCount = 0
            ElseIf elementCount = 0 Then
                elementCount = 1
            End If
            If elementCount > 0 AndAlso _
               fieldSize > MAX_GENERIC_ARRAY_BOUND_VALUE \ elementCount Then _
                Return -1
            Dim fieldOffset As Long = 0
            If isUnion = 0 Then
                fieldOffset = offset
                Dim remainder As Long = fieldOffset Mod fieldAlignment
                If remainder <> 0 Then
                    Dim padding As Long = fieldAlignment - remainder
                    If fieldOffset > MAX_GENERIC_ARRAY_BOUND_VALUE - padding Then _
                        Return -1
                    fieldOffset += padding
                End If
            End If
            If .sourceName = sourceField Then Return fieldOffset
            If isUnion = 0 AndAlso elementCount > 0 Then
                Dim memberSize As Long = fieldSize * elementCount
                If memberSize > MAX_GENERIC_ARRAY_BOUND_VALUE - fieldOffset Then _
                    Return -1
                offset = fieldOffset + memberSize
            End If
        End With
    Next
    Return -1
End Function

Private Function GenericHeaderBodyRecordFieldOffsetInBytes( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByVal sourceField As String _
) As Long
    If IsIdentifierToken(sourceField) = 0 Then Return -1
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceType, tokens(), tokenCount)
    If tokenCount = 0 OrElse tokenCount >= MAX_TYPE_WORDS Then Return -1
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel(tokens(), 0, tokenCount - 1, parsedType) = 0 OrElse _
       parsedType.hasUnsupportedSyntax <> 0 OrElse parsedType.pointerDepth <> 0 Then _
        Return -1
    Dim sourceRecordName As String = parsedType.baseName
    Dim isUnion As Long = 0
    Dim foundDeclaration As Long = 0
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               (.recordTag <> sourceRecordName AndAlso _
                .recordAlias <> sourceRecordName) Then Continue For
            If foundDeclaration <> 0 Then Return -1
            isUnion = CInt(.recordKind = C2FB_RECORD_UNION) * -1
            foundDeclaration = -1
        End With
    Next
    If foundDeclaration = 0 Then Return -1

    Dim offset As Long = 0
    Dim foundField As Long = 0
    For fieldIndex As Long = 0 To translation.body.recordFieldCount - 1
        With translation.body.recordFields(fieldIndex)
            If .ownerName <> sourceRecordName Then Continue For
            If .bitWidth >= 0 Then Return -1
            Dim fieldTokens() As String
            Dim fieldTokenCount As Long
            TokenizeCDeclaration(.sourceType, fieldTokens(), fieldTokenCount)
            If fieldTokenCount = 0 OrElse _
               fieldTokenCount >= MAX_TYPE_WORDS Then Return -1
            Dim parsedFieldType As C2fbCTypeModel
            If ParseCTypeModel( _
                fieldTokens(), 0, fieldTokenCount - 1, parsedFieldType) = 0 OrElse _
               parsedFieldType.hasUnsupportedSyntax <> 0 Then Return -1
            Dim pointerCount As Long = 0
            Dim isConst As Long = 0
            Dim freeBasicType As String = MapGenericHeaderCType( _
                translation, parsedFieldType, pointerCount, isConst, _
                C2FB_POINTER_MAPPING_PRESERVE)
            If freeBasicType = "" Then Return -1
            Dim fieldSize As Long = GenericHeaderSizeofTypeInBytes( _
                translation, .sourceType)
            Dim fieldAlignment As Long
            If pointerCount > 0 OrElse InStr(freeBasicType, " Ptr") <> 0 Then
                fieldAlignment = GenericHeaderPreprocessorSizeValue( _
                    translation, "__SIZEOF_POINTER__")
            Else
                Dim scalarSize As Long = GenericHeaderFreeBasicScalarSize( _
                    translation, freeBasicType)
                fieldAlignment = GenericHeaderFreeBasicScalarAlignment( _
                    translation, freeBasicType, scalarSize)
            End If
            If fieldAlignment <= 0 Then Return -1

            Dim elementCount As Long = 1
            If .isArray <> 0 Then
                If Trim(.arrayBound) = "" Then
                    elementCount = 0
                ElseIf EvaluateSimpleArrayBound( _
                    Trim(.arrayBound), elementCount, _
                    MAX_GENERIC_ARRAY_COUNT) = 0 OrElse elementCount < 0 Then
                    Return -1
                End If
            End If
            Dim fieldOffset As Long = 0
            If isUnion = 0 Then
                fieldOffset = offset
                Dim remainder As Long = fieldOffset Mod fieldAlignment
                If remainder <> 0 Then
                    Dim padding As Long = fieldAlignment - remainder
                    If fieldOffset > MAX_GENERIC_ARRAY_BOUND_VALUE - padding Then _
                        Return -1
                    fieldOffset += padding
                End If
            End If
            If .name = sourceField Then
                If foundField <> 0 Then Return -1
                foundField = -1
                If isUnion <> 0 Then Return 0
                Return fieldOffset
            End If
            If isUnion = 0 AndAlso elementCount > 0 Then
                If fieldSize < 0 OrElse _
                   fieldSize > MAX_GENERIC_ARRAY_BOUND_VALUE \ elementCount Then _
                    Return -1
                Dim memberSize As Long = fieldSize * elementCount
                If memberSize > MAX_GENERIC_ARRAY_BOUND_VALUE - fieldOffset Then _
                    Return -1
                offset = fieldOffset + memberSize
            End If
        End With
    Next
    Return -1
End Function

Private Function GenericHeaderReadOffsetofOperand( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByVal position As Long, _
    ByRef offsetValue As Long, ByRef nextPosition As Long _
) As Long
    offsetValue = 0
    nextPosition = position
    Dim operatorName As String
    Dim candidateNames(1) As String
    candidateNames(0) = "__builtin_offsetof"
    candidateNames(1) = "offsetof"
    For candidateIndex As Long = 0 To UBound(candidateNames)
        Dim candidateName As String = candidateNames(candidateIndex)
        If position < 1 OrElse position + Len(candidateName) - 1 > _
           Len(sourceExpression) OrElse _
           LCase(Mid(sourceExpression, position, Len(candidateName))) <> _
               candidateName Then Continue For
        If position > 1 AndAlso _
           IsIdentifierPart(Asc(sourceExpression, position - 1)) <> 0 Then _
            Continue For
        Dim afterOperator As Long = position + Len(candidateName)
        If afterOperator <= Len(sourceExpression) AndAlso _
           IsIdentifierPart(Asc(sourceExpression, afterOperator)) <> 0 Then _
            Continue For
        operatorName = candidateName
        Exit For
    Next
    If operatorName = "" Then Return 0

    Dim operandPosition As Long = position + Len(operatorName)
    SkipCSpaces(sourceExpression, operandPosition)
    If operandPosition > Len(sourceExpression) OrElse _
       Asc(sourceExpression, operandPosition) <> Asc("(") Then Return 0
    Dim groupEnd As Long = operandPosition
    If ScanSimpleExpressionGroup( _
        sourceExpression, groupEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim operands() As String
    Dim operandCount As Long
    Dim operandText As String = Trim(Mid( _
        sourceExpression, operandPosition + 1, _
        groupEnd - operandPosition - 2))
    If SplitSimpleCList(operandText, operands(), operandCount) = 0 OrElse _
       operandCount <> 2 Then Return 0
    offsetValue = GenericHeaderRecordFieldOffsetInBytes( _
        translation, Trim(operands(0)), Trim(operands(1)))
    If offsetValue < 0 Then
        offsetValue = GenericHeaderBodyRecordFieldOffsetInBytes( _
            translation, Trim(operands(0)), Trim(operands(1)))
    End If
    If offsetValue < 0 Then Return 0
    nextPosition = groupEnd
    Return -1
End Function

Private Function ReplaceGenericHeaderOffsetofExpressions( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, _
    ByRef normalizedExpression As String _
) As Long
    normalizedExpression = ""
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim offsetValue As Long
        Dim nextPosition As Long
        If GenericHeaderReadOffsetofOperand( _
            translation, sourceExpression, position, _
            offsetValue, nextPosition) <> 0 Then
            normalizedExpression &= Trim(Str(offsetValue))
            position = nextPosition
        Else
            normalizedExpression &= Mid(sourceExpression, position, 1)
            position += 1
        End If
    Wend
    Return CInt(normalizedExpression <> "")
End Function

Private Function GenericHeaderAlignmentOfTypeInBytes( _
    ByRef translation As C2fbTranslationContext, ByVal sourceType As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceType, tokens(), tokenCount)
    If tokenCount = 0 OrElse tokenCount >= MAX_TYPE_WORDS Then Return 0
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel(tokens(), 0, tokenCount - 1, parsedType) = 0 OrElse _
       parsedType.hasUnsupportedSyntax <> 0 OrElse _
       parsedType.isStruct <> 0 OrElse parsedType.isUnion <> 0 Then Return 0

    If parsedType.pointerDepth = 0 Then
        Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, parsedType.baseName, 0)
        If aliasIndex >= 0 AndAlso _
           translation.genericC.header.headerTypeAliases(aliasIndex).alignmentValue > 0 Then _
            Return translation.genericC.header.headerTypeAliases(aliasIndex).alignmentValue
    End If

    Dim pointerCount As Long = 0
    Dim isConst As Long = 0
    Dim freeBasicType As String = MapGenericHeaderCType( _
        translation, parsedType, pointerCount, isConst, _
        C2FB_POINTER_MAPPING_PRESERVE)
    If freeBasicType = "" Then Return 0
    If pointerCount > 0 OrElse InStr(freeBasicType, " Ptr") <> 0 Then _
        Return GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_POINTER__")

    Dim scalarSize As Long = GenericHeaderFreeBasicScalarSize( _
        translation, freeBasicType)
    If scalarSize <= 0 Then Return 0
    Return GenericHeaderFreeBasicScalarAlignment( _
        translation, freeBasicType, scalarSize)
End Function

Private Function GenericHeaderReadAlignofOperand( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByVal position As Long, _
    ByRef alignmentValue As Long, ByRef nextPosition As Long _
) As Long
    alignmentValue = 0
    nextPosition = position
    Dim operatorName As String
    Dim candidateNames(3) As String
    candidateNames(0) = "__alignof__"
    candidateNames(1) = "__alignof"
    candidateNames(2) = "_Alignof"
    candidateNames(3) = "alignof"
    For candidateIndex As Long = 0 To UBound(candidateNames)
        Dim candidateName As String = candidateNames(candidateIndex)
        If position < 1 OrElse position + Len(candidateName) - 1 > _
           Len(sourceExpression) OrElse _
           LCase(Mid(sourceExpression, position, Len(candidateName))) <> _
               candidateName Then Continue For
        If position > 1 AndAlso _
           IsIdentifierPart(Asc(sourceExpression, position - 1)) <> 0 Then _
            Continue For
        Dim afterOperator As Long = position + Len(candidateName)
        If afterOperator <= Len(sourceExpression) AndAlso _
           IsIdentifierPart(Asc(sourceExpression, afterOperator)) <> 0 Then _
            Continue For
        operatorName = candidateName
        Exit For
    Next
    If operatorName = "" Then Return 0

    Dim operandPosition As Long = position + Len(operatorName)
    SkipCSpaces(sourceExpression, operandPosition)
    If operandPosition > Len(sourceExpression) OrElse _
       Asc(sourceExpression, operandPosition) <> Asc("(") Then Return 0
    Dim groupEnd As Long = operandPosition
    If ScanSimpleExpressionGroup( _
        sourceExpression, groupEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim sourceType As String = Trim(Mid( _
        sourceExpression, operandPosition + 1, _
        groupEnd - operandPosition - 2))
    alignmentValue = GenericHeaderAlignmentOfTypeInBytes( _
        translation, sourceType)
    If alignmentValue <= 0 Then Return 0
    nextPosition = groupEnd
    Return -1
End Function

Private Function ReplaceGenericHeaderAlignofExpressions( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, _
    ByRef normalizedExpression As String _
) As Long
    normalizedExpression = ""
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim alignmentValue As Long
        Dim nextPosition As Long
        If GenericHeaderReadAlignofOperand( _
            translation, sourceExpression, position, _
            alignmentValue, nextPosition) <> 0 Then
            normalizedExpression &= Trim(Str(alignmentValue))
            position = nextPosition
        Else
            normalizedExpression &= Mid(sourceExpression, position, 1)
            position += 1
        End If
    Wend
    Return CInt(normalizedExpression <> "")
End Function

Private Function GenericHeaderIntegerTypeCanHoldSizeof( _
    ByRef translation As C2fbTranslationContext, _
    ByVal castType As String, ByVal sizeValue As Long _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(castType, tokens(), tokenCount)
    If tokenCount = 0 OrElse tokenCount >= MAX_TYPE_WORDS Then Return 0
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel(tokens(), 0, tokenCount - 1, parsedType) = 0 OrElse _
       parsedType.hasUnsupportedSyntax <> 0 OrElse _
       parsedType.isStruct <> 0 OrElse parsedType.isUnion <> 0 OrElse _
       parsedType.isEnum <> 0 OrElse parsedType.pointerDepth <> 0 Then Return 0
    If parsedType.baseName = "bool" OrElse parsedType.baseName = "_Bool" Then Return 0

    Dim pointerCount As Long = 0
    Dim isConst As Long = 0
    Dim freeBasicType As String = MapGenericHeaderCType( _
        translation, parsedType, pointerCount, isConst, _
        C2FB_POINTER_MAPPING_PRESERVE)
    If freeBasicType = "" OrElse pointerCount <> 0 OrElse _
       InStr(freeBasicType, " Ptr") <> 0 Then Return 0
    Dim storageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, freeBasicType, 0)
    If storageType <> "" Then freeBasicType = storageType

    Dim isUnsigned As Long = 0
    Select Case LCase(freeBasicType)
    Case "ubyte", "ushort", "ulong", "ulongint", "uinteger", "culong", _
         "c2fb_c_uint", "c2fb_c_ulong", "c2fb_uint64", "c2fb_size_t"
        isUnsigned = -1
    Case "byte", "short", "long", "longint", "integer", "clong", _
         "c2fb_c_int", "c2fb_c_long", "c2fb_int64"
    Case Else
        Return 0
    End Select

    Dim typeSize As Long = GenericHeaderFreeBasicScalarSize( _
        translation, freeBasicType)
    If typeSize <= 0 Then Return 0
    If typeSize >= 4 Then Return -1
    Dim maxValue As LongInt = 1
    Dim significantBits As Long = typeSize * 8 - CInt(isUnsigned = 0)
    For bitIndex As Long = 1 To significantBits
        maxValue *= 2
    Next
    maxValue -= 1
    Return CInt(sizeValue >= 0 AndAlso sizeValue <= maxValue) * -1
End Function

Private Function GenericHeaderReadStringLiteralSize( _
    ByVal sourceExpression As String, ByVal startPosition As Long, _
    ByRef sizeValue As Long, ByRef nextPosition As Long _
) As Long
    sizeValue = 0
    nextPosition = startPosition
    Dim position As Long = startPosition
    Dim contentByteCount As Long = 0
    Dim literalCount As Long = 0

    While position <= Len(sourceExpression)
        SkipCSpaces(sourceExpression, position)
        If position > Len(sourceExpression) Then Exit While
        If Mid(sourceExpression, position, 2) = "u8" AndAlso _
           Mid(sourceExpression, position + 2, 1) = Chr(34) Then
            position += 2
        End If
        If Mid(sourceExpression, position, 1) <> Chr(34) Then Exit While
        position += 1
        literalCount += 1

        Dim foundClosingQuote As Long = 0
        While position <= Len(sourceExpression)
            Dim currentByte As Long = Asc(sourceExpression, position)
            If currentByte = Asc(Chr(34)) Then
                position += 1
                foundClosingQuote = -1
                Exit While
            End If
            If currentByte = Asc(Chr(92)) Then
                position += 1
                If position > Len(sourceExpression) Then Return 0
                currentByte = Asc(sourceExpression, position)
                If currentByte = Asc("x") OrElse currentByte = Asc("X") Then
                    position += 1
                    Dim digitCount As Long = 0
                    While position <= Len(sourceExpression)
                        currentByte = Asc(sourceExpression, position)
                        If (currentByte >= Asc("0") AndAlso _
                            currentByte <= Asc("9")) OrElse _
                           (currentByte >= Asc("a") AndAlso _
                            currentByte <= Asc("f")) OrElse _
                           (currentByte >= Asc("A") AndAlso _
                            currentByte <= Asc("F")) Then
                            position += 1
                            digitCount += 1
                        Else
                            Exit While
                        End If
                    Wend
                    If digitCount = 0 Then Return 0
                ElseIf currentByte >= Asc("0") AndAlso _
                       currentByte <= Asc("7") Then
                    Dim digitCount As Long = 0
                    While position <= Len(sourceExpression) AndAlso _
                          digitCount < 3
                        currentByte = Asc(sourceExpression, position)
                        If currentByte < Asc("0") OrElse _
                           currentByte > Asc("7") Then Exit While
                        position += 1
                        digitCount += 1
                    Wend
                ElseIf currentByte = Asc("u") OrElse _
                       currentByte = Asc("U") Then
                    ' Universal character names need target execution-encoding
                    ' rules to determine their byte length.
                    Return 0
                Else
                    position += 1
                End If
            Else
                position += 1
            End If
            If contentByteCount >= MAX_GENERIC_ARRAY_BOUND_VALUE - 1 Then _
                Return 0
            contentByteCount += 1
        Wend
        If foundClosingQuote = 0 Then Return 0
        nextPosition = position
        Dim followingPosition As Long = position
        SkipCSpaces(sourceExpression, followingPosition)
        If Mid(sourceExpression, followingPosition, 1) <> Chr(34) AndAlso _
           Not (Mid(sourceExpression, followingPosition, 2) = "u8" AndAlso _
                Mid(sourceExpression, followingPosition + 2, 1) = Chr(34)) Then _
            Exit While
        position = followingPosition
    Wend

    If literalCount = 0 OrElse _
       contentByteCount >= MAX_GENERIC_ARRAY_BOUND_VALUE Then Return 0
    sizeValue = contentByteCount + 1
    Return -1
End Function

Private Function GenericHeaderReadSizeofOperand( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef position As Long, _
    ByRef sizeValue As Long, ByRef nextPosition As Long _
) As Long
    sizeValue = 0
    nextPosition = position
    If position < 1 OrElse position + 5 > Len(sourceExpression) OrElse _
       LCase(Mid(sourceExpression, position, 6)) <> "sizeof" Then Return 0
    If position > 1 AndAlso _
       IsIdentifierPart(Asc(sourceExpression, position - 1)) <> 0 Then Return 0
    If position + 6 <= Len(sourceExpression) AndAlso _
       IsIdentifierPart(Asc(sourceExpression, position + 6)) <> 0 Then Return 0
    position += 6
    SkipCSpaces(sourceExpression, position)
    If position > Len(sourceExpression) Then Return 0
    If Asc(sourceExpression, position) <> Asc("(") Then
        If GenericHeaderReadStringLiteralSize( _
            sourceExpression, position, sizeValue, nextPosition) <> 0 Then _
            Return -1
        If IsIdentifierStart(Asc(sourceExpression, position)) = 0 Then Return 0
        Dim macroStart As Long = position
        position += 1
        While position <= Len(sourceExpression) AndAlso _
              IsIdentifierPart(Asc(sourceExpression, position)) <> 0
            position += 1
        Wend
        Dim macroName As String = Mid( _
            sourceExpression, macroStart, position - macroStart)
        For macroIndex As Long = 0 To _
            translation.genericC.header.headerMacroCount - 1
            With translation.genericC.header.headerMacros(macroIndex)
                If .active = 0 OrElse _
                   .definition.sourceName <> macroName Then Continue For
                Dim literalEnd As Long
                If GenericHeaderReadStringLiteralSize( _
                    .definition.rawValue, 1, sizeValue, literalEnd) <> 0 AndAlso _
                   Trim(Mid(.definition.rawValue, literalEnd)) = "" Then
                    nextPosition = position
                    Return -1
                End If
            End With
        Next
        Return 0
    End If
    Dim groupEnd As Long = position
    If ScanSimpleExpressionGroup( _
        sourceExpression, groupEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim sourceType As String = Trim(Mid( _
        sourceExpression, position + 1, groupEnd - position - 2))
    Dim literalEnd As Long
    If GenericHeaderReadStringLiteralSize( _
        sourceType, 1, sizeValue, literalEnd) = 0 OrElse _
       Trim(Mid(sourceType, literalEnd)) <> "" Then
        sizeValue = GenericHeaderSizeofTypeInBytes(translation, sourceType)
    End If
    If sizeValue <= 0 Then Return 0
    nextPosition = groupEnd
    Return -1
End Function

Private Function ReplaceGenericHeaderSizeofExpressions( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, _
    ByRef normalizedExpression As String _
) As Long
    normalizedExpression = ""
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        If Asc(sourceExpression, position) = Asc("(") Then
            Dim castGroupEnd As Long = position
            If ScanSimpleExpressionGroup( _
                sourceExpression, castGroupEnd, Asc("("), Asc(")")) <> 0 Then
                Dim castType As String = Trim(Mid( _
                    sourceExpression, position + 1, _
                    castGroupEnd - position - 2))
                Dim sizeofPosition As Long = castGroupEnd
                SkipCSpaces(sourceExpression, sizeofPosition)
                Dim sizeValue As Long
                Dim afterSizeof As Long
                If GenericHeaderReadSizeofOperand( _
                    translation, sourceExpression, sizeofPosition, _
                    sizeValue, afterSizeof) <> 0 AndAlso _
                   GenericHeaderIntegerTypeCanHoldSizeof( _
                       translation, castType, sizeValue) <> 0 Then
                    normalizedExpression &= Trim(Str(sizeValue))
                    position = afterSizeof
                    Continue While
                End If
            End If
        End If

        Dim sizeValue As Long
        Dim afterSizeof As Long
        Dim sizeofPosition As Long = position
        If GenericHeaderReadSizeofOperand( _
            translation, sourceExpression, sizeofPosition, _
            sizeValue, afterSizeof) <> 0 Then
            normalizedExpression &= Trim(Str(sizeValue))
            position = afterSizeof
        Else
            normalizedExpression &= Mid(sourceExpression, position, 1)
            position += 1
        End If
    Wend
    Return -1
End Function


/' end of c2fb_generic_sizeof.bi '/
