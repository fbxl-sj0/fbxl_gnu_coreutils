/'
    Project: C2FB SQLite body policy

    File: c2fb_sqlite_body_policy.bi

    Purpose:

        Resolve SQLite-owned identifiers and port-specific body expression forms.

    Responsibilities:

        - Recognize SQLite constant-name families under the SQLite profile.
        - Map SQLite global names and window-function names to port accessors.
        - Preserve configuration-field access through stable port functions.

    This file intentionally does NOT contain:

        - General C expression parsing, precedence, or type inference.
        - C source collection, preprocessing, or generic C type mapping.
'/

Private Function IsSQLiteConstantIdentifierInContext( _
    ByRef translation As C2fbTranslationContext, ByVal identifier As String _
) As Long
    If translation.target.profile <> C2FB_TARGET_SQLITE Then Return 0
    Return CInt( _
        Left(identifier, 7) = "SQLITE_" OrElse _
        Left(identifier, 3) = "TK_" OrElse _
        Left(identifier, 3) = "OP_" OrElse _
        Left(identifier, 3) = "EP_" OrElse _
        Left(identifier, 3) = "SF_" OrElse _
        Left(identifier, 4) = "SRT_" OrElse _
        Left(identifier, 4) = "MEM_" OrElse _
        Left(identifier, 6) = "PAGER_" OrElse _
        Left(identifier, 6) = "PGHDR_" OrElse _
        Left(identifier, 6) = "BTREE_" OrElse _
        Left(identifier, 7) = "PTRMAP_")
End Function

Private Function SQLiteConfigFieldExpression( _
    ByVal fieldName As String, ByRef typeName As String _
) As String
    Select Case fieldName
    Case "bUseCis"
        typeName = "c2fb_c_int"
        Return "sqlite3ConfigCoveringIndexScanEnabled()"
    Case "bOpenUri"
        typeName = "c2fb_c_int"
        Return "sqlite3UriConfigEnabled()"
    Case "bCoreMutex"
        typeName = "c2fb_c_int"
        Return "sqlite3ConfigCoreMutexEnabled()"
    Case "bFullMutex"
        typeName = "c2fb_c_int"
        Return "sqlite3ConfigFullMutexEnabled()"
    Case "bMemstat"
        typeName = "c2fb_c_int"
        Return "sqlite3ConfigMemStatusEnabled()"
    Case "bExtraSchemaChecks"
        typeName = "c2fb_c_int"
        Return "sqlite3ConfigExtraSchemaChecksEnabled()"
    Case "sharedCacheEnabled"
        typeName = "c2fb_c_int"
        Return "sqlite3ConfigSharedCacheEnabled()"
    Case "szMmap"
        typeName = "c2fb_int64"
        Return "sqlite3ConfigMmapSizeDefault()"
    Case "mxMmap"
        typeName = "c2fb_int64"
        Return "sqlite3ConfigMmapSizeMaximum()"
    Case "szLookaside"
        typeName = "c2fb_c_int"
        Return "sqlite3ConfigLookasideSizeValue()"
    Case "nLookaside"
        typeName = "c2fb_c_int"
        Return "sqlite3ConfigLookasideCountValue()"
    Case "mxMemdbSize"
        typeName = "c2fb_int64"
        Return "sqlite3ConfigMemdbMaxSize()"
    Case "pcache2"
        typeName = "SqlitePcacheMethods2"
        Return "c2fbSqlitePcacheMethodsSnapshot()"
    End Select
    Return ""
End Function

Private Function TranslateSQLiteBodyIdentifier( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, ByVal identifier As String _
) As Long
    Select Case identifier
            Case "row_numberName", "dense_rankName", "rankName", _
                 "percent_rankName", "cume_distName", "ntileName", _
                 "last_valueName", "nth_valueName", "first_valueName", _
                 "leadName", "lagName"
                Dim windowNameId As String = ""
                Select Case identifier
                Case "row_numberName": windowNameId = "SQLITE_WINDOW_NAME_ROW_NUMBER"
                Case "dense_rankName": windowNameId = "SQLITE_WINDOW_NAME_DENSE_RANK"
                Case "rankName": windowNameId = "SQLITE_WINDOW_NAME_RANK"
                Case "percent_rankName": windowNameId = "SQLITE_WINDOW_NAME_PERCENT_RANK"
                Case "cume_distName": windowNameId = "SQLITE_WINDOW_NAME_CUME_DIST"
                Case "ntileName": windowNameId = "SQLITE_WINDOW_NAME_NTILE"
                Case "last_valueName": windowNameId = "SQLITE_WINDOW_NAME_LAST_VALUE"
                Case "nth_valueName": windowNameId = "SQLITE_WINDOW_NAME_NTH_VALUE"
                Case "first_valueName": windowNameId = "SQLITE_WINDOW_NAME_FIRST_VALUE"
                Case "leadName": windowNameId = "SQLITE_WINDOW_NAME_LEAD"
                Case "lagName": windowNameId = "SQLITE_WINDOW_NAME_LAG"
                End Select
                value.text = "sqlite3WindowFunctionName(" & windowNameId & ")"
                value.typeName = "Const ZString Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.isLValue = 0
                value.isReadOnly = -1
                value.isWholeCall = -1
                parser.hasFunctionCall = -1
            Case "noopStepFunc"
                ' Registration and VDBE generation compare this callback by
                ' address, so the helper returns the one registered pointer.
                value.text = "sqlite3WindowNoopStepFunction()"
                value.typeName = "Any Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.isLValue = 0
                value.isReadOnly = -1
                value.isWholeCall = -1
                parser.hasFunctionCall = -1
            Case "NULL", "false", "true"
                value.text = "Cast(c2fb_c_int, " & IIf(identifier = "true", "1", "0") & ")"
                value.typeName = "c2fb_c_int"
            Case "sqlite3CtypeMap", "sqlite3UpperToLower"
                ' Both byte tables are generated into sqlite3_global_data.bi.
                value.text = identifier
                value.typeName = "Const UByte Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.arrayElementType = "UByte"
                value.arrayBound = "256ULL"
                value.arrayCount = 256
                value.isLayoutArray = -1
                value.isLValue = -1
                value.isReadOnly = -1
            Case "sqlite3PendingByte"
                ' The B-tree pending-byte position is one exported C integer.
                value.text = identifier
                value.typeName = "c2fb_c_int"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.isLValue = -1
            Case "sqlite3SmallTypeSizes"
                ' The serial-length lookup table has a fixed 128-byte extent.
                value.text = identifier
                value.typeName = "Const UByte Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.arrayElementType = "UByte"
                value.arrayBound = "128ULL"
                value.arrayCount = 128
                value.isLayoutArray = -1
                value.isLValue = -1
                value.isReadOnly = -1
            Case "sqlite3OpcodeProperty"
                ' The opcode metadata table is generated into sqlite3_opcodes.bi.
                value.text = identifier
                value.typeName = "Const UByte Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.arrayElementType = "UByte"
                value.arrayBound = SIMPLE_UNKNOWN_ARRAY_BOUND
                value.isLayoutArray = -1
                value.isLValue = -1
                value.isReadOnly = -1
            Case "sqlite3StrBINARY"
                ' Some C code compares this global array by address. Keep one
                ' process-wide FreeBASIC storage object behind its accessor.
                value.text = "sqlite3StrBINARYName()"
                value.typeName = "Const ZString Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
            Case "aPragmaName"
                ' The source table is generated from pragma.c and stored in
                ' stable process-wide memory. Preserve its C array extent for
                ' sizeof while using pointer indexing for element access.
                value.text = "sqlite3PragmaNameTable()"
                value.typeName = "Const SqlitePragmaName Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.arrayElementType = "Const SqlitePragmaName"
                value.arrayBound = "SQLITE3_PRAGMA_NAME_COUNT"
            Case "pragCName"
                ' Column labels share the generated pragma data module. Keep
                ' its stable pointer table and source extent for indexed reads.
                value.text = "sqlite3PragmaColumnNameTable()"
                value.typeName = "Const ZString Ptr Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.arrayElementType = "Const ZString Ptr"
                value.arrayBound = "SQLITE3_PRAGMA_COLUMN_NAME_COUNT"
            Case "globInfo"
                value.text = "sqlite3GlobCompareInfo"
                value.typeName = "SqliteLikeCompareInfo"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.isLValue = -1
            Case "likeInfoNorm"
                value.text = "sqlite3LikeCompareInfo"
                value.typeName = "SqliteLikeCompareInfo"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.isLValue = -1
            Case "likeInfoAlt"
                value.text = "sqlite3LikeCompareInfoAlt"
                value.typeName = "SqliteLikeCompareInfo"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.isLValue = -1
            Case "sqlite3StdType"
                ' Keep the C global pointer table at one address so callers
                ' may safely retain or compare pointers obtained from it.
                value.text = "sqlite3StdTypeTable()"
                value.typeName = "Const ZString Ptr Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.arrayElementType = "Const ZString Ptr"
                value.arrayBound = "6ULL"
            Case "sqlite3_temp_directory", "sqlite3_data_directory"
                value.text = identifier
                value.typeName = "ZString Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.isLValue = -1
            Case "sqlite3BuiltinFunctions"
                value.text = identifier
                value.typeName = "SqliteGlobalBuiltinFunctions"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.cRecord = value.typeName
            Case "sqlite3Config"
                ' The port stores selected sqlite3Config fields separately.
                ' Resolve their reads through stable accessors below.
                value.text = identifier
                value.typeName = "SqliteGlobalConfig"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.cRecord = value.typeName
            Case "mem3"
                ' The optional MEMSYS3 allocator keeps its static state in one
                ' FreeBASIC record with the same field tree as struct Mem3Global.
                value.text = identifier
                value.typeName = "SqliteMem3Global"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.cRecord = "Mem3Global"
                value.isLValue = -1
            Case "aHardLimit"
                ' main.c's private hard-limit array shares storage with the
                ' port's limit implementation, which also initializes aLimit.
                value.text = "sqlite3LimitHardValueTable()"
                value.typeName = "Const c2fb_c_int Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.arrayElementType = "Const c2fb_c_int"
                value.arrayBound = "SQLITE_N_LIMIT"
                ' The accessor returns a pointer to the port-owned table, so
                ' use pointer indexing rather than BASIC fixed-array syntax.
                value.isLayoutArray = 0
                value.isLValue = 0
                value.isReadOnly = -1
                value.isWholeCall = -1
                parser.hasFunctionCall = -1
            Case "sqlite3BuiltinExtensions"
                ' The C array is a private list of initialization callbacks.
                ' The port supplies stable callback storage behind this accessor.
                Dim callbackType As String = _
                    CBodyBuiltinExtensionCallbackTypeInContext( _
                        parser.translation[0], parser.catalog[0])
                value.text = "CPtr(" & callbackType & " Ptr, c2fbBuiltinExtensionArray())"
                value.typeName = callbackType & " Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.arrayElementType = callbackType
                value.arrayBound = "c2fbBuiltinExtensionCount()"
                value.isLayoutArray = 0
                value.isLValue = 0
                value.isReadOnly = -1
                value.isWholeCall = -1
                parser.hasFunctionCall = -1
            Case "azCarrayType"
                ' carray.c's fixed string table is stored in the FreeBASIC
                ' feature module and exposed through a stable accessor.
                value.text = "sqlite3CarrayTypeTable()"
                value.typeName = "Const ZString Ptr Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.arrayElementType = "Const ZString Ptr"
                value.arrayBound = "5ULL"
                value.arrayCount = 5
                value.cRecord = "C2FB_CARRAY_TYPE_NAMES"
                value.isLValue = -1
                value.isReadOnly = -1
                value.isWholeCall = -1
                parser.hasFunctionCall = -1
            Case "kvvfsHexValue"
                ' os_kv.c keeps the signed 256-byte hex decoder table static.
                ' The optional FreeBASIC profile exposes stable table storage.
                value.text = "sqlite3KvHexValueTablePtr()"
                value.typeName = "Const Byte Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.arrayElementType = "Byte"
                value.arrayBound = "256ULL"
                value.arrayCount = 256
                value.isLayoutArray = 0
                value.isLValue = -1
                value.isReadOnly = -1
                value.isWholeCall = -1
                parser.hasFunctionCall = -1
            Case "sqlite3KvvfsMethods"
                ' The optional K/V VFS stores its record callbacks in a C global.
                ' Resolve its reads through a typed FreeBASIC table accessor.
                value.text = "sqlite3KvvfsMethodsPtr()"
                value.typeName = "SqliteKvvfsMethods Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.cRecord = "sqlite3_kvvfs_methods"
                value.isWholeCall = -1
                parser.hasFunctionCall = -1
    Case Else
        Return 0
    End Select
    Return -1
End Function

/' end of c2fb_sqlite_body_policy.bi '/
