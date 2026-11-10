/'
    Project: C2FB type resolution
    ----------------------------

    File: c2fb_type_resolution.bi

    Purpose:

        Map parsed C type shapes through the selected FreeBASIC target profile.

    Responsibilities:

        - Dispatch generic-header and function-body type resolution.
        - Apply generic ABI overrides and SQLite or portable body mappings.
        - Validate scalar and type-name use against the active translation context.
        - Preserve pointer depth and top-level constness for callers.
        - Return explicit status for invalid targets and unsupported C types.
        - Provide stable descriptions for type-resolution failures.

    This file intentionally does NOT contain:

        - C type syntax parsing or declarator parsing.
        - Declaration collection, symbol indexing, or output formatting.
'/

Private Function C2fbWideIntegerFreeBasicType( _
    ByVal typeWords As String _
) As String
    Select Case LCase(Trim(typeWords))
    Case "__int128", "signed __int128", "__int128 signed", _
         "__int128_t", "int128_t"
        Return "Integer<128>"
    Case "unsigned __int128", "__int128 unsigned", "__uint128_t", "uint128_t"
        Return "UInteger<128>"
    End Select
    Return ""
End Function

Private Function GenericHeaderTypeWordsMixTypedef( _
    ByRef translation As C2fbTranslationContext, ByVal typeWords As String _
) As Long
    If translation.genericC.header.headerTypeAliasCount = 0 Then Return 0
    Dim tokens() As String
    Dim tokenCount As Long = 0
    TokenizeCDeclaration(typeWords, tokens(), tokenCount)
    If tokenCount < 2 Then Return 0

    Dim foundTypedefName As Long = 0
    Dim foundOtherTypeSpecifier As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        If IsQualifierToken(tokens(tokenIndex)) <> 0 Then Continue For
        If tokens(tokenIndex) = "struct" OrElse tokens(tokenIndex) = "union" OrElse _
           tokens(tokenIndex) = "enum" Then Return 0
        If GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, tokens(tokenIndex), 0) >= 0 Then
            foundTypedefName += 1
        Else
            foundOtherTypeSpecifier = -1
        End If
    Next
    Return CInt(foundTypedefName > 0 AndAlso _
                (foundOtherTypeSpecifier <> 0 OrElse foundTypedefName > 1)) * -1
End Function

Private Function GenericHeaderTypeHasNonByteFlexibleTail( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByVal isTag As Long _
) As Long
    Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, sourceName, isTag)
    If aliasIndex < 0 Then Return 0
    Dim freeBasicName As String = _
        translation.genericC.header.headerTypeAliases(aliasIndex).freeBasicName
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        If translation.sourceUnit.declarations(declarationIndex).entryKind <> _
           C2FB_DECLARATION_RECORD Then Continue For
        With translation.genericC.header.recordPlans(declarationIndex)
            If .isPrepared = 0 OrElse .isSupported = 0 OrElse _
               .isExcluded <> 0 OrElse .hasNonByteFlexibleTail = 0 Then _
                Continue For
            If LCase(freeBasicName) = LCase(.freeBasicName) OrElse _
               LCase(freeBasicName) = LCase(.aliasFreeBasicName) Then Return -1
        End With
    Next
    Return 0
End Function

Private Function MapGenericHeaderCType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef parsedType As C2fbCTypeModel, _
    ByRef pointerCount As Long, ByRef isConst As Long, _
    ByVal pointerMappingPolicy As C2fbPointerMappingPolicy, _
    ByVal allowIncompleteValue As Long = 0 _
) As String
    pointerCount = 0
    isConst = 0
    pointerCount = parsedType.pointerDepth
    isConst = parsedType.isConst
    Dim typeWords As String = parsedType.baseName
    Dim sawEnumTag As Long = parsedType.isEnum
    Dim sawStructTag As Long = parsedType.isStruct
    Dim sawUnionTag As Long = parsedType.isUnion
    If typeWords = "void" AndAlso pointerCount = 0 Then Return "void"
    If GenericHeaderTypeWordsMixTypedef(translation, typeWords) <> 0 Then Return ""

    Dim baseType As String
    Dim knownType As Long = -1
    Dim typeOverride As String = GenericTypeOverrideInPolicy(translation.genericC.policy, typeWords)
    If typeOverride <> "" AndAlso _
       GenericTypeOverrideIsTypedefHintInPolicy( _
        translation.genericC.policy, typeWords) <> 0 AndAlso _
       GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, typeWords, 0) >= 0 Then _
        typeOverride = ""
    If typeOverride <> "" Then
        baseType = typeOverride
    ElseIf C2fbWideIntegerFreeBasicType(typeWords) <> "" Then
        baseType = C2fbWideIntegerFreeBasicType(typeWords)
        If pointerCount > 0 AndAlso _
           pointerMappingPolicy = C2FB_POINTER_MAPPING_OPAQUE Then _
            baseType = "Any"
    Else
    Dim useBuiltinJmpBuf As Long = CInt( _
        typeWords = "jmp_buf" AndAlso _
        GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, typeWords, 0) < 0)
    If useBuiltinJmpBuf <> 0 Then
        ' FBFrog treats jmp_buf as the FreeBASIC CRT array type when the C
        ' source does not provide its array typedef.
        baseType = "jmp_buf"
    Else
    Select Case typeWords
    Case "void"
        baseType = "Any"
    Case "char"
        If pointerCount = 0 Then
            baseType = "Byte"
        Else
            baseType = "ZString"
        End If
    Case "signed char", "int8_t", "__int8", "signed __int8"
        baseType = "Byte"
    Case "unsigned char", "uint8_t", "unsigned __int8"
        baseType = "UByte"
    Case "short", "short int", "signed short", "signed short int", _
         "int16_t", "__int16", "signed __int16"
        baseType = "Short"
    Case "unsigned short", "unsigned short int", "uint16_t", "unsigned __int16"
        baseType = "UShort"
    Case "int", "signed", "signed int", "int32_t", "__int32", "signed __int32"
        baseType = "Long"
    Case "unsigned", "unsigned int", "uint32_t", "unsigned __int32"
        baseType = "ULong"
    Case "long", "long int", "signed long", "signed long int"
        If translation.genericC.policy.cLong32 <> 0 Then
            baseType = "Long"
        Else
            baseType = "CLong"
        End If
    Case "unsigned long", "unsigned long int"
        If translation.genericC.policy.cLong32 <> 0 Then
            baseType = "ULong"
        Else
            baseType = "CULong"
        End If
    Case "long long", "long long int", "signed long long", "signed long long int", _
         "int64_t", "__int64", "signed __int64"
        baseType = "LongInt"
    Case "unsigned long long", "unsigned long long int", "uint64_t", _
         "unsigned __int64"
        baseType = "ULongInt"
    Case "size_t", "uintptr_t"
        baseType = "UInteger"
    Case "ptrdiff_t", "intptr_t", "ssize_t"
        ' FreeBASIC's CRT defines ssize_t as the signed pointer-width type.
        baseType = "Integer"
    Case "wchar_t"
        baseType = "wchar_t"
    Case "va_list", "__gnuc_va_list", "__builtin_va_list"
        baseType = "Cva_List"
    Case "_Bool", "bool"
        baseType = "Byte"
    Case "float"
        baseType = "Single"
    Case "double"
        baseType = "Double"
    Case "long double"
        baseType = "CLongDouble"
    Case Else
        If sawStructTag <> 0 OrElse sawUnionTag <> 0 Then
            Dim tagAlias As String = _
                GenericHeaderTagAliasNameInHeader(translation.genericC.header, typeWords)
            If tagAlias <> "" Then
                Dim tagIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
                    translation.genericC.header, typeWords, -1)
                If pointerCount = 0 AndAlso tagIndex >= 0 AndAlso _
                   translation.genericC.header.headerTypeAliases(tagIndex).isForward <> 0 AndAlso _
                   allowIncompleteValue = 0 Then _
                    Return ""
                If pointerCount = 0 AndAlso _
                   GenericHeaderTypeHasNonByteFlexibleTail( _
                       translation, typeWords, -1) <> 0 Then Return ""
                baseType = tagAlias
            Else
                If pointerCount = 0 AndAlso allowIncompleteValue <> 0 Then _
                    Return ""
                knownType = 0
                baseType = typeWords
            End If
        ElseIf sawEnumTag <> 0 Then
            Dim enumAlias As String = _
                GenericHeaderTagAliasNameInHeader(translation.genericC.header, typeWords)
            If enumAlias <> "" Then
                baseType = enumAlias
            Else
                baseType = "Long"
            End If
        Else
            Dim aliasIndex As Long = _
                GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, typeWords, 0)
            If aliasIndex >= 0 Then
                If pointerCount = 0 AndAlso _
                   translation.genericC.header.headerTypeAliases(aliasIndex).isForward <> 0 AndAlso _
                   allowIncompleteValue = 0 Then _
                    Return ""
                If pointerCount = 0 AndAlso _
                   GenericHeaderTypeHasNonByteFlexibleTail( _
                       translation, typeWords, 0) <> 0 Then Return ""
                If translation.genericC.header.headerTypeAliases(aliasIndex).isArray <> 0 Then
                    If pointerCount = 0 Then Return ""
                    baseType = "Any"
                Else
                    baseType = translation.genericC.header.headerTypeAliases(aliasIndex).freeBasicName
                    If translation.genericC.header.headerTypeAliases(aliasIndex).isFunction <> 0 Then
                        ' FreeBASIC's callback alias represents the source
                        ' typedef's function pointer layers. Only a C typedef
                        ' of a bare function type needs one implicit layer.
                        If pointerCount > 0 AndAlso _
                           translation.genericC.header.headerTypeAliases(aliasIndex).functionPointerDepth = 0 Then _
                            pointerCount -= 1
                    End If
                End If
            Else
                If pointerCount = 0 AndAlso allowIncompleteValue <> 0 Then _
                    Return ""
                knownType = 0
                baseType = typeWords
            End If
        End If
    End Select
    End If
    End If
    If pointerCount > 0 AndAlso pointerMappingPolicy = C2FB_POINTER_MAPPING_OPAQUE AndAlso _
       knownType = 0 AndAlso baseType <> "ZString" Then baseType = "Any"
    If pointerCount = 0 Then Return baseType

    Dim resultType As String
    If isConst <> 0 Then
        resultType = "Const " & baseType & " Ptr"
    Else
        resultType = baseType & " Ptr"
    End If
    For pointerIndex As Long = 2 To pointerCount
        resultType &= " Ptr"
    Next
    Return resultType
End Function

Private Function MapBodyCType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef parsedType As C2fbCTypeModel, _
    ByRef pointerCount As Long, _
    ByRef isConst As Long, _
    ByVal pointerMappingPolicy As C2fbPointerMappingPolicy, _
    ByVal recognitionPolicy As C2fbTypeRecognitionPolicy _
) As String
    pointerCount = 0
    isConst = 0
    Dim typeWords As String = parsedType.baseName
    pointerCount = parsedType.pointerDepth
    isConst = parsedType.isConst
    Dim sawEnumType As Long = parsedType.isEnum
    Dim baseType As String
    Dim explicitTypeOverride As String
    ' Explicit caller mappings apply to SQLite and generic body workflows. The
    ' selected target still controls every type that has no caller override.
    explicitTypeOverride = GenericTypeOverrideInPolicy( _
        translation.genericC.policy, typeWords)
    If explicitTypeOverride <> "" Then
        baseType = explicitTypeOverride
    ElseIf C2fbWideIntegerFreeBasicType(typeWords) <> "" Then
        baseType = C2fbWideIntegerFreeBasicType(typeWords)
        If pointerCount > 0 AndAlso _
           pointerMappingPolicy = C2FB_POINTER_MAPPING_OPAQUE Then _
            baseType = "Any"
    ElseIf C2fbIsWindowsEngineSource(translation) <> 0 AndAlso _
           ResolveC2fbWindowsAbiType( _
               typeWords, pointerCount, isConst, baseType) <> 0 Then
        ' SDK typedef groups are not always represented as one C2FB alias.
    ElseIf translation.target.profile <> C2FB_TARGET_SQLITE AndAlso _
           IsSQLiteBodySpecificType(typeWords) <> 0 Then
        baseType = LookupCBodyTypeAliasInContext( _
            translation, typeWords, pointerCount, isConst)
        If baseType = "" Then _
            baseType = LookupCBodyRecordBindingInContext(translation, typeWords)
        If baseType = "" Then _
            baseType = MappedFbBodyRecord(translation, catalog, typeWords)
        If baseType = "" Then _
            baseType = MappedFbBodyTypeAlias(translation, catalog, typeWords)
        If baseType = "" Then
            If pointerCount = 0 OrElse _
               recognitionPolicy = C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY Then Return ""
            baseType = "Any"
        End If
    Else
    Select Case typeWords
    Case "void"
        If pointerCount = 0 Then Return "void"
        baseType = "Any"
    Case "va_list", "__gnuc_va_list", "__builtin_va_list"
        ' FreeBASIC's Cva_List is the storage type used by Cva_Start/Arg/End.
        baseType = "Cva_List"
    Case "sqlite3_callback", "sqlite3_destructor_type", "sqlite3_syscall_ptr"
        If pointerMappingPolicy = C2FB_POINTER_MAPPING_PRESERVE Then
            Dim aliasType As String = LookupCBodyTypeAliasInContext( _
                translation, typeWords, pointerCount, isConst)
            If IsCBodyCallbackTypeInContext(translation, aliasType) <> 0 Then _
                Return aliasType
        End If
        baseType = "Any"
        pointerCount += 1
    Case "sqlite3_filename"
        baseType = "ZString"
        pointerCount += 1
        isConst = -1
    Case "Token"
        baseType = "sqlite3ParserToken"
    Case "sqlite3", "Btree", "BtShared", "BtCursor", "MemPage", "CellInfo", _
         "Pager", "PgHdr", "Hash", "HashElem", "HashBucket"
        baseType = typeWords
    Case "Vdbe"
        baseType = "SqliteVdbe"
    Case "sqlite3_stmt"
        ' SQLite's internal statement object is the VDBE itself.
        baseType = "SqliteVdbe"
    Case "Mem"
        baseType = "SqliteVdbeMem"
    Case "Expr"
        baseType = "SqliteExpr"
    Case "ExprList"
        baseType = "SqliteExprList"
    Case "ExprList_item"
        baseType = "SqliteExprListItem"
    Case "IdList_item"
        baseType = "SqliteIdListItem"
    Case "Select"
        baseType = "SqliteSelect"
    Case "Parse"
        baseType = "SqliteParseContext"
    Case "SubrtnSig"
        baseType = "SqliteSubroutineSignature"
    Case "char"
        If pointerCount = 0 Then
            baseType = "Byte"
        Else
            baseType = "ZString"
        End If
    Case "signed char", "i8"
        baseType = "Byte"
    Case "unsigned char", "u8"
        baseType = "UByte"
    Case "short", "short int", "signed short", "signed short int", "i16"
        baseType = "Short"
    Case "LogEst"
        baseType = "Short"
    Case "Bitmask"
        ' The default SQLite source configuration defines Bitmask as u64.
        baseType = "sqlite3_uint64"
    Case "unsigned short", "unsigned short int", "u16"
        baseType = "UShort"
    Case "int", "signed", "signed int", "sqlite3_int", "i32"
        baseType = "c2fb_c_int"
    Case "unsigned", "unsigned int", "u32"
        baseType = "c2fb_c_uint"
    Case "long", "long int", "signed long", "signed long int"
        baseType = "c2fb_c_long"
    Case "unsigned long", "unsigned long int"
        baseType = "c2fb_c_ulong"
    Case "long long", "long long int", "signed long long", "signed long long int", _
         "sqlite3_int64", "sqlite_int64", "i64"
        baseType = "c2fb_int64"
    Case "unsigned long long", "unsigned long long int", "sqlite3_uint64", "u64"
        baseType = "c2fb_uint64"
    Case "size_t"
        baseType = "c2fb_size_t"
    Case "ptrdiff_t"
        ' ptrdiff_t is ABI-defined; use its mapped C typedef when available.
        baseType = GenericTypeOverrideInPolicy( _
            translation.genericC.policy, typeWords)
        If baseType = "" Then _
            baseType = LookupCBodyTypeAliasInContext( _
                translation, typeWords, pointerCount, isConst)
        If baseType = "" Then _
            baseType = MappedFbBodyTypeAlias( _
                translation, catalog, typeWords)
        If baseType = "" Then baseType = "Integer"
    Case "wchar_t"
        baseType = GenericTypeOverrideInPolicy( _
            translation.genericC.policy, typeWords)
        If baseType = "" Then _
            baseType = MappedFbBodyTypeAlias(translation, catalog, typeWords)
        If baseType = "" Then baseType = "wchar_t"
    Case "float"
        baseType = "Single"
    Case "double"
        baseType = "Double"
    Case "long double"
        baseType = "CLongDouble"
    Case "_Bool", "bool"
        baseType = "Byte"
    Case "void *"
        baseType = "Any Ptr"
    Case Else
        baseType = LookupCBodyTypeAliasInContext( _
            translation, typeWords, pointerCount, isConst)
        If baseType = "" Then _
            baseType = LookupCBodyRecordBindingInContext(translation, typeWords)
        If baseType = "" Then _
            baseType = MappedFbBodyRecord(translation, catalog, typeWords)
        If baseType = "" Then _
            baseType = MappedFbBodyTypeAlias(translation, catalog, typeWords)
        If Len(baseType) <> 0 Then
            ' A typedef's qualifiers and pointer levels belong to its type.
        ElseIf sawEnumType <> 0 Then
            ' C enums use the target C int representation unless the source
            ' compiler applies an extension that changes its underlying type.
            baseType = "c2fb_c_int"
        ElseIf pointerCount > 0 Then
            If recognitionPolicy = C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY Then Return ""
            baseType = "Any"
        ElseIf parsedType.isStruct <> 0 OrElse parsedType.isUnion <> 0 Then
            ' An unmapped record has no safe scalar representation. Guessing
            ' C int here turns member access into invalid BASIC at compile time.
            Return ""
        ElseIf translation.target.profile <> C2FB_TARGET_SQLITE Then
            Return ""
        Else
            If recognitionPolicy = C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY Then Return ""
            ' C enum typedefs have int ABI. Unknown scalar aliases are emitted
            ' as C int so the generated declarations remain self-contained.
            baseType = "c2fb_c_int"
        End If
    End Select
    Dim hasBodyTypedef As Long = 0
    For aliasIndex As Long = 0 To translation.body.aliasCount - 1
        If translation.body.aliases(aliasIndex).name = typeWords Then
            hasBodyTypedef = -1
            Exit For
        End If
    Next
    If pointerCount > 0 AndAlso hasBodyTypedef = 0 AndAlso _
       IsMappedFbBodyProcedureTypeAlias(catalog, baseType) <> 0 Then
        ' A FreeBASIC Function/Sub type already represents one C function
        ' pointer level. PUTTER * therefore maps directly to that alias.
        pointerCount -= 1
    End If
    End If

    If baseType <> "" Then
        Dim generatedRecordAlias As String = _
            LookupCBodyGeneratedRecordBindingInContext(translation, baseType)
        If generatedRecordAlias <> "" Then baseType = generatedRecordAlias
    End If

    If translation.target.profile <> C2FB_TARGET_SQLITE AndAlso _
       baseType <> "" Then
        ' A typedef record alias resolves first to its C tag. Convert that
        ' tag to the body binding's FreeBASIC record name before adding the
        ' pointer levels, so nested fields through the typedef stay typed.
        Dim mappedRecordAlias As String = _
            LookupCBodyRecordBindingInContext(translation, baseType)
        If mappedRecordAlias = "" Then _
            mappedRecordAlias = MappedFbBodyRecord(translation, catalog, baseType)
        If mappedRecordAlias <> "" Then baseType = mappedRecordAlias
    End If

    ' A typedef to C void carries no pointee layout. Keep the typedef for
    ' source recognition, then use FreeBASIC's opaque pointer type wherever it
    ' appears behind one or more C pointer operators.
    If baseType = "void" AndAlso pointerCount > 0 Then baseType = "Any"

    If pointerMappingPolicy = C2FB_POINTER_MAPPING_OPAQUE AndAlso pointerCount > 0 Then
        Select Case typeWords
        Case "sqlite3", "sqlite3_stmt", "Btree", "BtShared", "BtCursor", "MemPage", "CellInfo", _
             "Pager", "PgHdr", "Hash", "HashElem", "HashBucket", "Vdbe", "Mem", _
             "Expr", "ExprList", "ExprList_item", "IdList_item", _
             "Select", "Parse", "Token"
            ' ABI headers must not require the engine's structure definitions.
            ' Candidate bodies still request typed pointers for field access.
            baseType = "Any"
        End Select
    End If
    If pointerCount = 0 Then Return baseType
    Dim resultType As String
    If isConst <> 0 AndAlso baseType = "ZString" Then
        resultType = "Const ZString Ptr"
    ElseIf isConst <> 0 Then
        ' Preserve const on opaque void pointers. C2FB emits explicit casts
        ' for const void* call arguments, and the parameter declaration must
        ' retain the same FreeBASIC type for the call to remain well-typed.
        resultType = "Const " & baseType & " Ptr"
    Else
        resultType = baseType & " Ptr"
    End If
    For i As Long = 2 To pointerCount
        resultType &= " Ptr"
    Next
    Return resultType
End Function

Private Sub ResolveC2fbTypeModel( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    tokens() As String, _
    ByVal firstToken As Long, _
    ByVal lastToken As Long, _
    ByRef resolvedType As C2fbResolvedTypeModel, _
    ByVal pointerMappingPolicy As C2fbPointerMappingPolicy = C2FB_POINTER_MAPPING_PRESERVE, _
    ByVal mappingKind As C2fbTypeMappingKind = C2FB_TYPE_MAPPING_BODY, _
    ByVal recognitionPolicy As C2fbTypeRecognitionPolicy = _
        C2FB_TYPE_RECOGNITION_ALLOW_FALLBACK, _
    ByVal allowIncompleteValue As Long = 0 _
)
    resolvedType.status = C2FB_TYPE_RESOLUTION_INVALID
    resolvedType.freeBasicType = ""
    resolvedType.pointerCount = 0
    resolvedType.isConst = 0
    resolvedType.volatileMask = 0
    If C2fbTargetProfileIsValid(translation.target.profile) = 0 Then
        resolvedType.status = C2FB_TYPE_RESOLUTION_INVALID_TARGET
        Exit Sub
    End If
    If pointerMappingPolicy <> C2FB_POINTER_MAPPING_PRESERVE AndAlso _
       pointerMappingPolicy <> C2FB_POINTER_MAPPING_OPAQUE Then
        resolvedType.status = C2FB_TYPE_RESOLUTION_INVALID_OPTIONS
        Exit Sub
    End If
    If recognitionPolicy <> C2FB_TYPE_RECOGNITION_ALLOW_FALLBACK AndAlso _
       recognitionPolicy <> C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY Then
        resolvedType.status = C2FB_TYPE_RESOLUTION_INVALID_OPTIONS
        Exit Sub
    End If
    If mappingKind <> C2FB_TYPE_MAPPING_BODY AndAlso _
       mappingKind <> C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        resolvedType.status = C2FB_TYPE_RESOLUTION_INVALID_MAPPING
        Exit Sub
    End If
    If mappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER AndAlso _
       translation.target.profile <> C2FB_TARGET_GENERIC Then
        resolvedType.status = C2FB_TYPE_RESOLUTION_INVALID_TARGET
        Exit Sub
    End If
    If mappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER AndAlso _
       recognitionPolicy <> C2FB_TYPE_RECOGNITION_ALLOW_FALLBACK Then
        resolvedType.status = C2FB_TYPE_RESOLUTION_INVALID_OPTIONS
        Exit Sub
    End If
    If allowIncompleteValue <> 0 AndAlso _
       mappingKind <> C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        resolvedType.status = C2FB_TYPE_RESOLUTION_INVALID_OPTIONS
        Exit Sub
    End If
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel( _
        tokens(), firstToken, lastToken, parsedType) = 0 Then
        resolvedType.status = C2FB_TYPE_RESOLUTION_UNSUPPORTED_SYNTAX
        Exit Sub
    End If
    If parsedType.hasUnsupportedSyntax <> 0 Then
        resolvedType.status = C2FB_TYPE_RESOLUTION_UNSUPPORTED_SYNTAX
        Exit Sub
    End If
    resolvedType.volatileMask = parsedType.volatileMask
    If mappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        resolvedType.freeBasicType = MapGenericHeaderCType( _
            translation, parsedType, resolvedType.pointerCount, _
            resolvedType.isConst, pointerMappingPolicy, allowIncompleteValue)
    Else
        resolvedType.freeBasicType = MapBodyCType( _
            translation, catalog, parsedType, resolvedType.pointerCount, _
            resolvedType.isConst, pointerMappingPolicy, recognitionPolicy)
    End If
    If resolvedType.freeBasicType = "" Then
        resolvedType.pointerCount = 0
        resolvedType.isConst = 0
        resolvedType.status = C2FB_TYPE_RESOLUTION_UNMAPPED_TYPE
        Exit Sub
    End If
    Dim targetPointerDepth As Long = resolvedType.pointerCount
    If mappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        targetPointerDepth = GenericFreeBasicTypePointerDepthInHeader( _
            translation.genericC.header, resolvedType.freeBasicType, 0)
    End If
    If targetPointerDepth > MAX_FREEBASIC_POINTER_LEVELS Then
        resolvedType.freeBasicType = ""
        resolvedType.pointerCount = 0
        resolvedType.status = C2FB_TYPE_RESOLUTION_UNSUPPORTED_POINTER_DEPTH
        Exit Sub
    End If
    resolvedType.status = C2FB_TYPE_RESOLUTION_RESOLVED
End Sub

Private Function C2fbTypeResolutionFailureDescription( _
    ByVal status As C2fbTypeResolutionStatus _
) As String
    Select Case status
    Case C2FB_TYPE_RESOLUTION_INVALID
        Return "type resolution did not complete"
    Case C2FB_TYPE_RESOLUTION_INVALID_TARGET
        Return "invalid target profile"
    Case C2FB_TYPE_RESOLUTION_INVALID_MAPPING
        Return "invalid type mapping kind"
    Case C2FB_TYPE_RESOLUTION_INVALID_OPTIONS
        Return "invalid type mapping options"
    Case C2FB_TYPE_RESOLUTION_UNSUPPORTED_SYNTAX
        Return "unsupported C type syntax"
    Case C2FB_TYPE_RESOLUTION_UNMAPPED_TYPE
        Return "no mapping for type under target profile"
    Case C2FB_TYPE_RESOLUTION_UNSUPPORTED_POINTER_DEPTH
        Return "pointer depth exceeds FreeBASIC's configured limit"
    Case Else
        Return "unknown type resolution status"
    End Select
End Function

Private Function IsTypeOrQualifierTokenInContext( _
    ByRef translation As C2fbTranslationContext, ByVal text As String _
) As Long
    Select Case text
    Case "const", "volatile", "restrict", "__restrict", "__restrict__", _
         "register", "signed", "unsigned", _
         "void", "char", "short", "int", "long", "float", "double", "struct", "enum", _
         "bool", "_Bool", "wchar_t", "int8_t", "uint8_t", "int16_t", "uint16_t", _
         "int32_t", "uint32_t", "int64_t", "uint64_t", "intptr_t", "uintptr_t", _
         "__int8", "__int16", "__int32", "__int64", "size_t", "ptrdiff_t", _
         "va_list", "__gnuc_va_list", "__builtin_va_list", _
         "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", _
         "LogEst", "Bitmask", "sqlite3_int64", "sqlite3_uint64", "sqlite_int64", "sqlite3_filename", _
         "sqlite3_callback", "sqlite3_destructor_type", "sqlite3_syscall_ptr", _
         "jmp_buf", "Token"
        Return -1
    End Select
    Dim pointerCount As Long = 0
    Dim isConst As Long = 0
    Dim mappedType As String
    If GenericTypeOverrideInPolicy(translation.genericC.policy, text) <> "" Then Return -1
    If LookupCBodyTypeAliasInContext( _
        translation, text, pointerCount, isConst) <> "" Then Return -1
    If C2fbIsWindowsEngineSource(translation) <> 0 AndAlso _
       ResolveC2fbWindowsAbiType(text, pointerCount, isConst, mappedType) <> 0 Then _
        Return -1
    Return 0
End Function

Private Function C2fbTypeRecognitionStatusInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    tokens() As String, _
    ByVal firstToken As Long, _
    ByVal lastToken As Long _
) As C2fbTypeResolutionStatus
    Dim resolvedType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        translation, catalog, tokens(), firstToken, lastToken, resolvedType, _
        C2FB_POINTER_MAPPING_PRESERVE, C2FB_TYPE_MAPPING_BODY, _
        C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
    Return resolvedType.status
End Function
/' end of c2fb_type_resolution.bi '/
