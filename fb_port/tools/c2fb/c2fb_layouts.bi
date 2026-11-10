/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_layouts.bi

    Purpose:

        Adapt C member access to the structure declarations owned by the port.

    Responsibilities:

        - Read field types and fixed-array declarations from FreeBASIC headers.
        - Index numeric-width FreeBASIC bitfield members.
        - Index public and module-private FreeBASIC record declarations.
        - Index public fields for bounded owner-and-member lookup.
        - Distinguish array indexing from pointer indexing in generated code.
        - Retain layout names for navigation through nested member expressions.
        - Resolve record aliases before matching fields and nested records.
        - Map parser, name-resolution, SELECT, Walker/DbFixer, AuthContext, _
          RETURNING, index-coverage, window, pragma, JSON, backup, B-tree payload, _
          foreign-key, trigger, scan-status, cursor-hint, MEMSYS3, carray, _
          group-concat, and optional vtab records.

    This file intentionally does NOT contain:

        - C layout validation or inference of missing port fields.
        - C arithmetic type inference from a potentially partial port layout.
'/

Private Const MAX_C2FB_FB_LAYOUT_NESTING As Long = 32

Private Type C2fbFbLayoutScanStateModel
    typeNames(0 To MAX_C2FB_FB_LAYOUT_NESTING - 1) As String
    typePrivate(0 To MAX_C2FB_FB_LAYOUT_NESTING - 1) As Long
    typeIsUnion(0 To MAX_C2FB_FB_LAYOUT_NESTING - 1) As Long
    typeDepth As Long
End Type

Private Function FbBodyRecordHasExactFields( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As Long
    If Left(typeName, 6) = "Const " Then typeName = Mid(typeName, 7)
    While Right(typeName, 4) = " Ptr"
        typeName = Left(typeName, Len(typeName) - 4)
    Wend
    Return CInt(C2fbStringIndexMapLookup( _
        catalog.bodyRecordOwnerMap, LCase(typeName)) >= 0) * -1
End Function

Private Function FbBodyRecordHasPublicFields( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String, _
    ByVal caseInsensitive As Long = 0 _
) As Long
    If caseInsensitive <> 0 Then
        Return CInt(C2fbStringIndexMapLookup( _
            catalog.bodyPublicRecordOwnerMap, LCase(typeName)) >= 0) * -1
    End If
    Return CInt(C2fbStringIndexMapLookup( _
        catalog.bodyPublicRecordOwnerExactMap, typeName) >= 0) * -1
End Function

/' Built once for the source tree and reused by each serial file conversion. '/
Private Function ResolveFbBodyRecordAlias( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As String
    Dim resolvedName As String = typeName
    For depth As Long = 1 To 32
        Dim nextName As String = ""
        Dim aliasIndex As Long = C2fbStringIndexMapLookup( _
            catalog.bodyTypeAliasMap, LCase(resolvedName))
        If aliasIndex >= 0 AndAlso aliasIndex < catalog.bodyTypeAliasCount Then
            ' A complete record can coexist in the source tree with an opaque
            ' alias of the same name from another module. Keep the complete
            ' layout for member access instead of following the opaque alias.
            If FbBodyRecordHasExactFields(catalog, resolvedName) <> 0 Then _
                Exit For
            With catalog.bodyTypeAliases(aliasIndex)
                If .isPrivate = 0 Then
                    Dim targetName As String = .targetName
                    If Left(LCase(LTrim(targetName)), 9) <> "function " AndAlso _
                       Left(LCase(LTrim(targetName)), 4) <> "sub " Then _
                        nextName = targetName
                End If
            End With
        End If
        If nextName = "" OrElse LCase(nextName) = LCase(resolvedName) Then Exit For
        resolvedName = nextName
    Next
    Return resolvedName
End Function

Private Function ResolveFbBodyRecordOwner( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As String
    If Left(typeName, 6) = "Const " Then typeName = Mid(typeName, 7)
    For depth As Long = 1 To 32
        While Right(typeName, 4) = " Ptr"
            typeName = Left(typeName, Len(typeName) - 4)
        Wend
        Dim resolvedName As String = ResolveFbBodyRecordAlias(catalog, typeName)
        If resolvedName = typeName Then Exit For
        typeName = resolvedName
    Next
    While Right(typeName, 4) = " Ptr"
        typeName = Left(typeName, Len(typeName) - 4)
    Wend
    Return typeName
End Function

Private Function MappedFbBodyFieldName( _
    ByRef translation As C2fbTranslationContext, _
    ByVal ownerName As String, ByVal fieldName As String _
) As String
    If Left(ownerName, 6) = "Const " Then ownerName = Mid(ownerName, 7)
    If translation.target.profile <> C2FB_TARGET_SQLITE Then
        If C2fbFreeBasicFieldIdentifierNeedsEscape(fieldName) <> 0 Then _
            Return fieldName & "_"
        Return fieldName
    End If
    If ownerName = "SqliteMem3BlockList" Then
        Select Case fieldName
        Case "next": Return "nextBlock"
        Case "prev": Return "previousBlock"
        End Select
    ElseIf ownerName = "SqliteGroupConcatContext" Then
        Select Case fieldName
        Case "str": Return "accumulator"
        Case "nAccum": Return "termCount"
        Case "nFirstSepLength": Return "firstSeparatorLength"
        Case "pnSepLengths": Return "separatorLengths"
        End Select
    End If
    If LCase(ownerName) = "sqlite3" AndAlso fieldName = "errCode" Then _
        Return "errorCode"
    If ownerName = "UnixFile" Then
        ' The Unix port groups the C sqlite3_file prefix and uses explicit
        ' names for descriptor, inode, deferred-close, and SHM state.
        Select Case fieldName
        Case "h": Return "fd"
        Case "eFileLock": Return "lockLevel"
        Case "pInode": Return "pLockInfo"
        Case "pPreallocatedUnused": Return "pDeferred"
        Case "pShm": Return "pShmNode"
        End Select
    ElseIf ownerName = "UnixLockInfo" Then
        If fieldName = "pUnused" Then Return "pDeferred"
    ElseIf ownerName = "AfpByteRangeLockPB2" Then
        Select Case fieldName
        Case "retRangeStart": Return "returnRangeStart"
        Case "unLockFlag": Return "unlockFlag"
        End Select
    End If
    If LCase(ownerName) = "sqlitewindowcodecontext" AndAlso fieldName = "end" Then _
        Return "ending"
    If ownerName = "SqliteBytecodeVtabCursor" AndAlso fieldName = "sub" Then _
        Return "subprogram"
    If ownerName = "SqliteDateTime" Then
        Select Case fieldName
        Case "M": Return "month"
        Case "m": Return "minute"
        End Select
    End If
    If C2fbFreeBasicFieldIdentifierNeedsEscape(fieldName) <> 0 Then _
        Return fieldName & "_"
    Return fieldName
End Function

Private Function CBodyFreeBasicFieldNameForAccess( _
    ByRef translation As C2fbTranslationContext, _
    ByVal ownerName As String, ByVal sourceFieldName As String, _
    ByVal sourceFieldIndex As Long = -1 _
) As String
    Dim mappedName As String = MappedFbBodyFieldName( _
        translation, ownerName, sourceFieldName)
    If sourceFieldIndex < 0 OrElse _
       sourceFieldIndex >= translation.body.recordFieldCount Then Return mappedName
    With translation.body.recordFields(sourceFieldIndex)
        If LCase(.name) <> LCase(sourceFieldName) OrElse _
           .freeBasicName = "" Then Return mappedName
        Dim defaultName As String = sourceFieldName
        If C2fbFreeBasicFieldIdentifierNeedsEscape(defaultName) <> 0 Then _
            defaultName &= "_"
        If translation.target.profile <> C2FB_TARGET_SQLITE OrElse _
           LCase(mappedName) = LCase(defaultName) Then Return .freeBasicName
    End With
    Return mappedName
End Function

Private Function MappedFbBitFieldStorageField( _
    ByRef translation As C2fbTranslationContext, _
    ByVal ownerName As String, ByVal fieldName As String _
) As String
    If Left(ownerName, 6) = "Const " Then ownerName = Mid(ownerName, 7)
    If translation.target.profile <> C2FB_TARGET_SQLITE Then Return ""
    If ownerName = "SqliteVdbeCursor" Then
        Select Case fieldName
        Case "isEphemeral", "useRandomRowid", "isOrdered", "noReuse", "colCache"
            ' SQLite packs these C bitfields into the port's cursorFlags word.
            Return "cursorFlags"
        End Select
    ElseIf ownerName = "SqliteSrcItemFlags" OrElse _
           ownerName = "SqliteExprListFlags" OrElse _
           ownerName = "SqliteColumn" OrElse _
           ownerName = "SqliteIndex" OrElse _
           ownerName = "SqliteWhereInfo" OrElse _
           ownerName = "SqliteWhereInfoRecord" Then
        ' The port stores these C bitfield groups in one named integer field.
        Return "flags"
    ElseIf ownerName = "SqliteDbInitInfo" Then
        Select Case fieldName
        Case "orphanTrigger", "imposterTable", "reopenMemdb"
            ' sqlite3InitInfo packs these consecutive flags into init.flags.
            Return "flags"
        End Select
    End If
    Return ""
End Function

Private Function LookupFbBodyField( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal ownerName As String, ByVal fieldName As String, _
    ByVal sourceFieldIndex As Long = -1 _
) As Long
    If Left(ownerName, 6) = "Const " Then ownerName = Mid(ownerName, 7)
    ownerName = ResolveFbBodyRecordOwner(catalog, ownerName)
    fieldName = CBodyFreeBasicFieldNameForAccess( _
        translation, ownerName, fieldName, sourceFieldIndex)
    Dim key As String = LCase(ownerName) & Chr(1) & LCase(fieldName)
    Dim fieldIndex As Long = C2fbStringIndexMapLookup( _
        catalog.bodyFieldIndex, key)
    If fieldIndex >= 0 AndAlso fieldIndex < catalog.bodyFieldCount AndAlso _
       catalog.bodyFields(fieldIndex).isPrivate = 0 Then Return fieldIndex
    Return -1
End Function

Private Function C2fbBodyFieldIndexKey( _
    ByVal ownerName As String, ByVal fieldName As String _
) As String
    Return LCase(ownerName) & Chr(1) & LCase(fieldName)
End Function

Private Sub IndexC2fbBodyField( _
    ByRef catalog As C2fbProjectCatalog, ByVal fieldIndex As Long _
)
    If fieldIndex < 0 OrElse fieldIndex >= catalog.bodyFieldCount Then Exit Sub
    With catalog.bodyFields(fieldIndex)
        If .isPrivate <> 0 OrElse .name = "" Then Exit Sub
        Dim ownerKey As String = LCase(.ownerName)
        If C2fbStringIndexMapLookup( _
            catalog.bodyPublicRecordOwnerMap, ownerKey) < 0 Then
            If AddC2fbStringIndexMapEntry( _
                catalog.bodyPublicRecordOwnerMap, ownerKey, fieldIndex) = 0 Then _
                ReportError("public FreeBASIC record-owner index exceeds the configured limit")
        End If
        If C2fbStringIndexMapLookup( _
            catalog.bodyPublicRecordOwnerExactMap, .ownerName) < 0 Then
            If AddC2fbStringIndexMapEntry( _
                catalog.bodyPublicRecordOwnerExactMap, .ownerName, fieldIndex) = 0 Then _
                ReportError("exact public FreeBASIC record-owner index exceeds the configured limit")
        End If
        Dim key As String = C2fbBodyFieldIndexKey(.ownerName, .name)
        If C2fbStringIndexMapLookup(catalog.bodyFieldIndex, key) >= 0 Then Exit Sub
        If AddC2fbStringIndexMapEntry( _
            catalog.bodyFieldIndex, key, fieldIndex) = 0 Then _
            ReportError("FreeBASIC body field index exceeds the configured limit")
    End With
End Sub

Private Sub RebuildC2fbBodyFieldIndex( _
    ByRef catalog As C2fbProjectCatalog _
)
    ResetC2fbStringIndexMap(catalog.bodyPublicRecordOwnerMap)
    ResetC2fbStringIndexMap(catalog.bodyPublicRecordOwnerExactMap)
    ResetC2fbStringIndexMap(catalog.bodyFieldIndex)
    For fieldIndex As Long = 0 To catalog.bodyFieldCount - 1
        IndexC2fbBodyField(catalog, fieldIndex)
    Next
End Sub

Private Function FbBodyRecordHasFieldModel( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As Long
    Dim ownerName As String = ResolveFbBodyRecordOwner(catalog, typeName)
    Return FbBodyRecordHasExactFields(catalog, ownerName)
End Function

Private Function NormalizeFbBodyType( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As String
    Dim qualifier As String
    If Left(typeName, 6) = "Const " Then
        qualifier = "Const "
        typeName = Mid(typeName, 7)
    End If
    Dim pointerCount As Long = 0
    While Right(typeName, 4) = " Ptr"
        typeName = Left(typeName, Len(typeName) - 4)
        pointerCount += 1
    Wend
    Dim resolvedType As String = ResolveFbBodyRecordAlias(catalog, typeName)
    If pointerCount > 0 AndAlso _
       Left(LCase(resolvedType), Len("_c2fb_record_")) = "_c2fb_record_" AndAlso _
       FbBodyRecordHasFieldModel(catalog, resolvedType) = 0 Then
        ' Generic headers retain pointer-only aliases for records whose C
        ' layout was filtered or unsupported. Preserve that usable alias until
        ' a member access requires the complete backing Type.
        resolvedType = typeName
    End If
    If resolvedType <> typeName Then
        If Left(resolvedType, 6) = "Const " Then
            qualifier = "Const "
            resolvedType = Mid(resolvedType, 7)
        End If
        While Right(resolvedType, 4) = " Ptr"
            resolvedType = Left(resolvedType, Len(resolvedType) - 4)
            pointerCount += 1
        Wend
        typeName = resolvedType
    End If
    Select Case LCase(typeName)
    Case "long", "i32", "sqlite_c_int": typeName = "c2fb_c_int"
    Case "ulong", "u32", "sqlite_c_uint": typeName = "c2fb_c_uint"
    Case "clong", "sqlite_c_long": typeName = "c2fb_c_long"
    Case "culong", "sqlite_c_ulong": typeName = "c2fb_c_ulong"
    Case "longint", "i64", "sqlite3_int64", "sqlite_int64": typeName = "c2fb_int64"
    Case "ulongint", "u64", "sqlite3_uint64": typeName = "c2fb_uint64"
    Case "uinteger", "sqlite_size_t": typeName = "c2fb_size_t"
    ' ssize_t is signed and pointer-sized in the selected C/FreeBASIC target.
    Case "ssize_t": typeName = "Integer"
    Case "u8": typeName = "UByte"
    Case "i8": typeName = "Byte"
    Case "u16": typeName = "UShort"
    Case "i16": typeName = "Short"
    End Select
    Dim result As String = qualifier & typeName
    For pointerIndex As Long = 1 To pointerCount
        result &= " Ptr"
    Next
    Return result
End Function

Private Function IsSimpleFbTypeAliasTarget(ByVal typeName As String) As Long
    Dim loweredTarget As String = LCase(LTrim(typeName))
    If Left(loweredTarget, 9) = "function " OrElse _
       Left(loweredTarget, 4) = "sub " Then Return -1
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(typeName, tokens(), tokenCount)
    If tokenCount = 0 OrElse tokenCount > 16 Then Return 0
    Dim foundBaseType As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case LCase(tokens(tokenIndex))
        Case "const"
            If foundBaseType <> 0 Then Return 0
        Case "ptr"
            If foundBaseType = 0 Then Return 0
        Case Else
            If IsIdentifierToken(tokens(tokenIndex)) = 0 OrElse foundBaseType <> 0 Then Return 0
            foundBaseType = -1
        End Select
    Next
    Return foundBaseType
End Function

Private Function IsMappedFbBodyProcedureTypeAlias( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As Long
    Dim aliasIndex As Long = C2fbStringIndexMapLookup( _
        catalog.bodyTypeAliasMap, LCase(typeName))
    If aliasIndex >= 0 AndAlso aliasIndex < catalog.bodyTypeAliasCount Then
        Dim loweredTarget As String = _
            LCase(LTrim(catalog.bodyTypeAliases(aliasIndex).targetName))
        Return CInt(Left(loweredTarget, 9) = "function " OrElse _
                    Left(loweredTarget, 4) = "sub ") * -1
    End If
    Return 0
End Function

Private Function MappedFbBodyRecord( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As String
    If translation.target.profile <> C2FB_TARGET_SQLITE Then
        Dim explicitlyMappedType As String = GenericTypeOverrideInPolicy( _
            translation.genericC.policy, sourceName)
        If explicitlyMappedType <> "" AndAlso _
           explicitlyMappedType <> "Any" AndAlso _
           InStr(explicitlyMappedType, " Ptr") = 0 Then
            ' A body type map is the caller's assertion that the complete C
            ' record uses this FreeBASIC layout. Use its fields when resolving
            ' sizeof on the mapped C type.
            Dim explicitlyMappedOwner As String = ResolveFbBodyRecordOwner( _
                catalog, explicitlyMappedType)
            If FbBodyRecordHasPublicFields( _
                catalog, explicitlyMappedOwner, -1) <> 0 Then _
                Return explicitlyMappedType
        End If
        Dim directName As String = sourceName
        Dim directAliasMatched As Long = 0
        Dim directAliasIndex As Long = C2fbStringIndexMapLookup( _
            catalog.bodyTypeAliasMap, LCase(sourceName))
        If directAliasIndex >= 0 AndAlso _
           directAliasIndex < catalog.bodyTypeAliasCount AndAlso _
           catalog.bodyTypeAliases(directAliasIndex).aliasName = sourceName Then
            directName = ResolveFbBodyRecordOwner(catalog, sourceName)
            directAliasMatched = -1
        End If
        If sourceName = "win_syscall" Then directName = "WinSystemCallEntry"
        If FbBodyRecordHasPublicFields( _
            catalog, directName, directAliasMatched) <> 0 Then Return sourceName
        ' Generic header output uses this prefix by default. Reuse its record
        ' aliases when a body is translated against the generated binding, so
        ' callers do not need to repeat a type map for every matching record.
        Dim generatedPrefix As String = _
            translation.genericC.policy.generatedNamePrefix
        If generatedPrefix = "" Then generatedPrefix = "c2fb_"
        Dim generatedName As String = generatedPrefix & sourceName
        Dim generatedAliasIndex As Long = C2fbStringIndexMapLookup( _
            catalog.bodyTypeAliasMap, LCase(generatedName))
        Dim generatedTarget As String = generatedName
        Dim generatedAliasMatched As Long = 0
        If generatedAliasIndex >= 0 AndAlso _
           generatedAliasIndex < catalog.bodyTypeAliasCount AndAlso _
           catalog.bodyTypeAliases(generatedAliasIndex).aliasName = generatedName Then
            generatedTarget = ResolveFbBodyRecordOwner(catalog, generatedName)
            generatedAliasMatched = -1
        End If
        If FbBodyRecordHasPublicFields( _
            catalog, generatedTarget, generatedAliasMatched) <> 0 Then _
            Return generatedName
        Return ""
    End If
    Dim fbName As String = sourceName
    Select Case sourceName
    Case "Walker": fbName = "SqliteWalker"
    Case "DbFixer": fbName = "SqliteDbFixer"
    Case "Token": fbName = "sqlite3ParserToken"
    Case "AuthContext": fbName = "SqliteAuthContext"
    Case "Parse": fbName = "SqliteParseContext"
    Case "TableLock": fbName = "SqliteTableLock"
    Case "sqlite3InitInfo": fbName = "SqliteDbInitInfo"
    Case "InitData": fbName = "SqliteInitData"
    Case "CollSeq": fbName = "sqlite3CollSeq"
    Case "FuncDef": fbName = "SqliteFuncDef"
    Case "FuncDestructor": fbName = "SqliteFuncDestructor"
    Case "ScanStatus": fbName = "SqliteScanStatus"
    Case "PreUpdate": fbName = "SqlitePreUpdateApiState"
    Case "PreUpdate.uKey": fbName = "sqlite3VdbeKeyInfoPrefix"
    ' pager.h aliases DbPage to the page-cache header record.
    Case "DbPage": fbName = "PgHdr"
    Case "sqlite3_context": fbName = "SqliteResultContext"
    ' vdbe.h aliases the internal Mem tag to sqlite3_value.
    Case "sqlite3_value", "Mem": fbName = "SqliteVdbeMem"
    Case "DbpageTable": fbName = "SqliteDbpageTable"
    Case "DbpageCursor": fbName = "SqliteDbpageCursor"
    ' os_unix.c records map onto the port's private Unix VFS layouts.
    Case "unixFile": fbName = "UnixFile"
    Case "unixInodeInfo": fbName = "UnixLockInfo"
    Case "unix_syscall": fbName = "UnixSystemCallEntry"
    Case "ByteRangeLockPB2": fbName = "AfpByteRangeLockPB2"
    Case "win_syscall": fbName = "WinSystemCallEntry"
    Case "sqlite3_mem_methods": fbName = "SqliteMemMethods"
    Case "Mem3Global": fbName = "SqliteMem3Global"
    Case "Mem3Block": fbName = "SqliteMem3Block"
    Case "Mem3Block.u": fbName = "SqliteMem3BlockUnion"
    Case "Mem3Block.u.hdr": fbName = "SqliteMem3BlockHeader"
    Case "Mem3Block.u.list": fbName = "SqliteMem3BlockList"
    Case "MemStore": fbName = "MemdbStore"
    Case "MemFile": fbName = "MemdbFile"
    Case "MemFS": fbName = "MemdbFileSystem"
    Case "Db": fbName = "SqliteDbSlot"
    Case "DbClientData": fbName = "SqliteDbClientData"
    Case "Schema": fbName = "SqliteSchema"
    Case "Savepoint": fbName = "SqliteSavepoint"
    Case "SrcItem": fbName = "SqliteSrcItem"
    ' __builtin_offsetof on Expr fields must inspect the port's real layout.
    Case "Expr": fbName = "SqliteExpr"
    ' ExprList owns a one-element FreeBASIC placeholder for its C flexible tail.
    Case "ExprList": fbName = "SqliteExprList"
    Case "SelectDest": fbName = "SqliteSelectDest"
    Case "ExprList_item": fbName = "SqliteExprListItem"
    Case "IdList_item": fbName = "SqliteIdListItem"
    Case "DistinctCtx": fbName = "SqliteDistinctContext"
    Case "SubstContext": fbName = "SqliteSubstContext"
    Case "RowLoadInfo": fbName = "SqliteRowLoadInfo"
    Case "VtabCtx": fbName = "SqliteVtabContext"
    Case "StatTable": fbName = "SqliteDbstatTable"
    Case "StatCursor": fbName = "SqliteDbstatCursor"
    Case "StatPage": fbName = "SqliteDbstatPage"
    Case "StatCell": fbName = "SqliteDbstatCell"
    Case "KVVfsFile": fbName = "SqliteKvvfsFile"
    Case "sqlite3_kvvfs_methods": fbName = "SqliteKvvfsMethods"
    Case "carray_bind": fbName = "SqliteCarrayBind"
    Case "carray_cursor": fbName = "SqliteCarrayCursor"
    Case "bytecodevtab": fbName = "SqliteBytecodeVtab"
    Case "bytecodevtab_cursor": fbName = "SqliteBytecodeVtabCursor"
    Case "SortCtx": fbName = "SqliteSortContext"
    Case "DeferredCsr": fbName = "SqliteDeferredCsr"
    Case "IdxCover": fbName = "SqliteIdxCover"
    Case "VdbeOp", "Op": fbName = "SqliteVdbeOp"
    Case "VdbeFrame": fbName = "SqliteVdbeFrame"
    Case "DblquoteStr": fbName = "SqliteDblquoteStr"
    Case "VdbeOpList": fbName = "SqliteVdbeOpList"
    Case "UnpackedRecord": fbName = "sqlite3VdbeUnpackedRecord"
    Case "KeyInfo": fbName = "sqlite3VdbeKeyInfoPrefix"
    Case "Wal": fbName = "SqliteWal"
    Case "WalIndexHdr": fbName = "SqliteWalIndexHeader"
    Case "WalCkptInfo": fbName = "SqliteWalCheckpointInfo"
    Case "WalHashLoc": fbName = "SqliteWalHashLocation"
    Case "WalIterator": fbName = "SqliteWalIterator"
    Case "WalIterator.WalSegment", "WalSegment": fbName = "SqliteWalSegment"
    Case "WalWriter": fbName = "SqliteWalWriter"
    Case "VdbeCursor": fbName = "SqliteVdbeCursor"
    Case "TreeView": fbName = "SqliteTreeView"
    Case "SubProgram": fbName = "SqliteVdbeSubProgram"
    Case "AuxData": fbName = "SqliteVdbeAuxData"
    Case "BtreePayload": fbName = "SqliteBtreePayload"
    Case "With": fbName = "SqliteWithRecord"
    Case "Cte": fbName = "SqliteCte"
    Case "CteUse": fbName = "SqliteCteUse"
    Case "WhereInfo": fbName = "SqliteWhereInfo"
    Case "CCurHint": fbName = "SqliteCursorHint"
    Case "WhereLevel": fbName = "SqliteWhereLevel"
    Case "WhereLoop": fbName = "SqliteWhereLoop"
    Case "WhereTerm": fbName = "SqliteWhereTerm"
    Case "WhereClause": fbName = "SqliteWhereClause"
    Case "WhereMaskSet": fbName = "SqliteWhereMaskSet"
    Case "WhereRightJoin": fbName = "SqliteWhereRightJoin"
    Case "WhereLoopBuilder": fbName = "SqliteWhereLoopBuilder"
    Case "WherePath": fbName = "SqliteWherePath"
    Case "WhereOrCost": fbName = "SqliteWhereOrCost"
    Case "WhereOrSet": fbName = "SqliteWhereOrSet"
    Case "WhereScan": fbName = "SqliteWhereScan"
    Case "WhereMemBlock": fbName = "SqliteWhereMemBlock"
    Case "IndexedExpr": fbName = "SqliteIndexedExpr"
    Case "WhereOrInfo": fbName = "SqliteWhereOrInfo"
    Case "WhereAndInfo": fbName = "SqliteWhereAndInfo"
    Case "IntegrityCk": fbName = "SqliteIntegrityCk"
    Case "Window": fbName = "SqliteWalkerWindow"
    Case "WindowRewrite": fbName = "SqliteWindowRewriteContext"
    Case "WindowUpdate": fbName = "SqliteWindowUpdateRule"
    Case "WindowCodeArg": fbName = "SqliteWindowCodeContext"
    Case "WindowCsrAndReg": fbName = "SqliteWindowCursorRegister"
    Case "SorterFile": fbName = "SqliteSorterFilePrefix"
    Case "SorterList": fbName = "SqliteSorterListPrefix"
    Case "SorterRecord": fbName = "SqliteSorterRecordPrefix"
    Case "SorterRecord.u": fbName = "SqliteSorterRecordUnion"
    Case "PmaReader": fbName = "SqlitePmaReaderPrefix"
    Case "MergeEngine": fbName = "SqliteMergeEnginePrefix"
    Case "IncrMerger": fbName = "SqliteIncrMergerPrefix"
    Case "SortSubtask": fbName = "SqliteSortSubtaskPrefix"
    Case "VdbeSorter": fbName = "SqliteVdbeSorterPrefix"
    Case "PmaWriter": fbName = "SqlitePmaWriter"
    Case "PgHdr1": fbName = "SqlitePcache1Page"
    Case "PCache1": fbName = "SqlitePcache1"
    Case "PGroup": fbName = "SqlitePcache1Group"
    Case "PgFreeslot": fbName = "SqlitePcache1FreeSlot"
    Case "PCacheGlobal": fbName = "SqlitePcache1Global"
    Case "CallCount": fbName = "SqliteWindowCallCount"
    Case "NthValueCtx": fbName = "SqliteWindowNthValueCtx"
    Case "NtileCtx": fbName = "SqliteWindowNtileCtx"
    Case "LastValueCtx": fbName = "SqliteWindowLastValueCtx"
    Case "CellArray": fbName = "BtreeCellArray"
    Case "Index": fbName = "SqliteIndex"
    Case "IndexSample": fbName = "SqliteIndexSample"
    Case "ValueNewStat4Ctx": fbName = "SqliteValueNewStat4Context"
    Case "StatSample": fbName = "SqliteStatSample"
    Case "StatAccum": fbName = "SqliteStatAccum"
    Case "analysisInfo": fbName = "SqliteAnalysisInfo"
    Case "Percentile": fbName = "SqlitePercentileContext"
    Case "IndexIterator": fbName = "SqliteIndexIterator"
    Case "IndexListTerm": fbName = "SqliteIndexListTerm"
    Case "IndexIterator.u": fbName = "SqliteIndexIteratorUnion"
    Case "Table": fbName = "SqliteTable"
    Case "Column": fbName = "SqliteColumn"
    Case "IdList": fbName = "SqliteIdList"
    Case "Subquery": fbName = "SqliteSubquery"
    Case "FKey": fbName = "SqliteFKey"
    Case "sColMap": fbName = "SqliteFKeyColumn"
    Case "Trigger": fbName = "SqliteTrigger"
    Case "TriggerStep": fbName = "SqliteTriggerStep"
    Case "Upsert": fbName = "SqliteUpsert"
    Case "RenameToken": fbName = "SqliteRenameToken"
    Case "RenameCtx": fbName = "SqliteRenameContext"
    Case "Returning": fbName = "SqliteReturning"
    Case "SrcList": fbName = "SqliteSrcList"
    Case "DateTime": fbName = "SqliteDateTime"
    Case "sqlite3_index_info": fbName = "SqliteIndexInfo"
    Case "sqlite3_index_constraint": fbName = "SqliteIndexConstraint"
    Case "sqlite3_index_orderby": fbName = "SqliteIndexOrderBy"
    Case "sqlite3_index_constraint_usage": fbName = "SqliteIndexConstraintUsage"
    Case "HiddenIndexInfo": fbName = "SqliteHiddenIndexInfo"
    Case "sqlite3_vtab": fbName = "SqliteVtab"
    Case "sqlite3_vtab_cursor": fbName = "SqliteVtabCursor"
    Case "sqlite3_module": fbName = "SqliteModuleCallbacks"
    Case "Module": fbName = "SqliteModule"
    Case "VTable": fbName = "SqliteVTable"
    Case "NameContext": fbName = "SqliteNameContext"
    Case "AggInfo": fbName = "SqliteAggInfo"
    Case "AggInfo_col": fbName = "SqliteAggInfoColumn"
    Case "AggInfo_func": fbName = "SqliteAggInfoFunction"
    Case "RefSrcList": fbName = "SqliteRefSrcList"
    Case "CheckOnCtx": fbName = "SqliteCheckOnContext"
    Case "JsonParent": fbName = "SqliteJsonParent"
    Case "JsonEachCursor": fbName = "SqliteJsonEachCursor"
    Case "JsonEachConnection": fbName = "SqliteJsonEachConnection"
    Case "PragmaName": fbName = "SqlitePragmaName"
    Case "PragmaVtab": fbName = "SqlitePragmaVtab"
    Case "PragmaVtabCursor": fbName = "SqlitePragmaVtabCursor"
    Case "EncName": fbName = "SqlitePragmaEncodingName"
    Case "FuncDef.u": fbName = "SqliteFuncDefUnion"
    Case "sqlite3_backup": fbName = "SqliteBackupContext"
    Case "StrAccum": fbName = "sqlite3_str"
    Case "SumCtx": fbName = "SqliteSumContext"
    Case "GroupConcatCtx": fbName = "SqliteGroupConcatContext"
    End Select
    Dim explicitTypeMap As String = _
        GenericTypeOverrideInPolicy(translation.genericC.policy, sourceName)
    If explicitTypeMap <> "" Then
        fbName = explicitTypeMap
    ElseIf fbName = sourceName Then
        ' A body record binding may have matched an existing generated
        ' c2fb_<CRecord> layout through its fields. Reuse that binding for
        ' flexible-array helpers and other layout-aware expression paths.
        For bindingIndex As Long = 0 To translation.body.recordBindingCount - 1
            If translation.body.recordBindings(bindingIndex).sourceName = _
               sourceName Then
                fbName = translation.body.recordBindings(bindingIndex).fbName
                Exit For
            End If
        Next
    End If
    If explicitTypeMap = "" AndAlso fbName = sourceName Then
        ' Reuse a conventional c2fb_<CRecord> layout when it was supplied
        ' through the SQLite FreeBASIC source directory, even if the C record
        ' has no precomputed record binding in this input unit.
        Dim sqliteGeneratedPrefix As String = _
            translation.genericC.policy.generatedNamePrefix
        If sqliteGeneratedPrefix = "" Then sqliteGeneratedPrefix = "c2fb_"
        Dim sqliteGeneratedName As String = sqliteGeneratedPrefix & sourceName
        Dim sqliteGeneratedOwner As String = _
            ResolveFbBodyRecordOwner(catalog, sqliteGeneratedName)
        If FbBodyRecordHasPublicFields( _
            catalog, sqliteGeneratedOwner, -1) <> 0 Then _
            fbName = sqliteGeneratedName
    End If
    ' Some port records are FreeBASIC Type aliases over their storage record.
    ' Match fields through the resolved owner while keeping the public alias in
    ' the translated expression.
    Dim resolvedFbName As String = ResolveFbBodyRecordAlias(catalog, fbName)
    If FbBodyRecordHasPublicFields(catalog, resolvedFbName, -1) <> 0 Then _
        Return fbName
    Return ""
End Function

Private Function MappedFbBodyTypeAlias( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As String
    If translation.target.profile = C2FB_TARGET_SQLITE Then Return ""
    Dim generatedPrefix As String = _
        translation.genericC.policy.generatedNamePrefix
    If generatedPrefix = "" Then generatedPrefix = "c2fb_"
    Dim generatedName As String = generatedPrefix & sourceName
    Dim aliasIndex As Long = C2fbStringIndexMapLookup( _
        catalog.bodyTypeAliasMap, LCase(generatedName))
    If aliasIndex >= 0 AndAlso aliasIndex < catalog.bodyTypeAliasCount AndAlso _
       catalog.bodyTypeAliases(aliasIndex).aliasName = generatedName Then _
        Return generatedName
    Return ""
End Function

Private Function CBodyRecordHasUnmeasuredFlexibleTail( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String _
) As Long
    For fieldIndex As Long = 0 To translation.body.recordFieldCount - 1
        With translation.body.recordFields(fieldIndex)
            If .ownerName <> sourceName OrElse .isArray = 0 OrElse _
               (.arrayBound <> "" AndAlso .arrayBound <> "0") Then Continue For
            If .pointerCount <> 0 OrElse _
               (LCase(.sourceType) <> "char" AndAlso _
                LCase(.sourceType) <> "unsigned char") Then Return -1
        End With
    Next
    Return 0
End Function

Private Function CBodyRecordSizeIsKnown( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As Long
    For bindingIndex As Long = 0 To translation.body.recordBindingCount - 1
        With translation.body.recordBindings(bindingIndex)
            ' Anonymous nested records use owner.field names and already have
            ' layouts in the current source-unit type context.
            If (.isGenerated <> 0 OrElse InStr(.sourceName, ".") <> 0) AndAlso _
               .sourceName = sourceName Then Return -1
        End With
    Next
    If GenericTypeOverrideInPolicy( _
        translation.genericC.policy, sourceName) <> "" Then
        ' An explicit type map is a caller assertion that this C record uses
        ' the indexed public FreeBASIC record layout.
        Return CInt(MappedFbBodyRecord(translation, catalog, sourceName) <> "")
    End If
    If translation.target.profile <> C2FB_TARGET_SQLITE Then
        If CBodyRecordHasUnmeasuredFlexibleTail( _
            translation, sourceName) <> 0 Then Return 0
        Return CInt(MappedFbBodyRecord(translation, catalog, sourceName) <> "")
    End If
    Select Case sourceName
    ' The opaque connection handle is allocated from the port's own record.
    ' Its size is private to the FreeBASIC implementation, so use that layout
    ' for sqlite3MallocZero(sizeof(sqlite3)) without claiming C offset parity.
    Case "sqlite3": Return -1
    ' Nested SQL parsing saves the port-owned Parse tail as one local byte array.
    ' Size and offsets therefore follow SqliteParseContext for body lowering.
    Case "Parse": Return -1
    ' TableLock has the same four fields and target padding in C and the port.
    Case "TableLock": Return -1
    ' The AFP fsctl packet has a fixed 32-byte FreeBASIC layout checked at OS init.
    Case "ByteRangeLockPB2": Return -1
    ' The Windows syscall entry is three pointer-sized fields.
    Case "win_syscall": Return -1
    ' Token is the fixed borrowed SQL text span mapped to sqlite3ParserToken.
    Case "Token": Return -1
    ' Select and InitData have fixed, complete records in their mapped headers.
    Case "Select", "InitData", "AuthContext": Return -1
    ' Cte and CteUse are fixed records used by WITH-clause processing.
    Case "Cte", "CteUse": Return -1
    ' Cte is a fixed element; With offsets are derived from its trailing array.
    Case "Cte": Return -1
    ' Table and Db map to complete fixed records in the default profile.
    Case "Table", "Db": Return -1
    ' Cursor and shared-cache lock sizes match the fixed btreeInt.h records.
    Case "BtCursor", "BtLock": Return -1
    ' These records are safe only when the active C fields match the port.
    Case "Btree", "BtShared"
        Return CBodyMappedRecordLayoutMatchesActiveC( _
            translation, catalog, sourceName)
    ' Pager allocations use the port's extended MemPage, including aiOvflSize.
    Case "MemPage": Return -1
    ' SumCtx mirrors the fixed numeric aggregate accumulator exactly.
    Case "SumCtx": Return -1
    ' GroupConcatCtx uses the port-owned accumulator and callback state.
    ' Its size intentionally follows SqliteGroupConcatContext, not C sizeof.
    Case "GroupConcatCtx": Return -1
    ' sqlite3_value is the VDBE Mem record; debug-only tail fields share guards.
    Case "sqlite3_value", "Mem", "IntegrityCk": Return -1
    ' SrcItem is fixed; SrcList.a is sized from its trailing item array.
    Case "SrcItem": Return -1
    ' Index is a fixed record in the default profile and maps to SqliteIndex.
    ' SQLITE_ENABLE_STAT4 appends fields in both source and port layouts.
    Case "Index", "IndexSample", "ValueNewStat4Ctx", "StatSample", "StatAccum", _
         "analysisInfo", "Percentile", _
         "IndexIterator", "IndexIterator.u", "IndexListTerm": Return -1
    ' CellArray has six fixed stages in both btree.c and sqlite3_btree.bi.
    Case "CellArray": Return -1
    ' VdbeOpList is the four-byte constant opcode tuple used by VdbeAddOpList.
    Case "VdbeOpList", "UnpackedRecord", "CellInfo", "sqlite3_value": Return -1
    ' VdbeFrame is a fixed nested-program frame preceding its child arrays.
    Case "VdbeFrame": Return -1
    ' SubrtnSig is the fixed P4 signature record in sqlite3_vdbe_core.bi.
    Case "SubrtnSig": Return -1
    ' DblquoteStr has a fixed header and an eight-byte allocation placeholder.
    Case "DblquoteStr": Return -1
    ' Expr and its value unions are complete in the default engine profile.
    Case "Expr", "Expr.y": Return -1
    ' Flexible ExprList and IdList allocations use these fixed element layouts.
    Case "ExprList_item", "IdList_item": Return -1
    ' Walker has a pointer-sized union in both the C and FreeBASIC records.
    Case "Walker": Return -1
    ' Public virtual-table planner records have complete fixed layouts.
    Case "sqlite3_index_info", "sqlite3_index_constraint", _
         "sqlite3_index_orderby", "sqlite3_index_constraint_usage": Return -1
    ' Window and its aggregate contexts have complete fixed layouts.
    Case "Window", "WindowRewrite", "WindowUpdate", "WindowCodeArg", _
         "WindowCsrAndReg", "CallCount", "NthValueCtx", "NtileCtx", "LastValueCtx": Return -1
    ' Trigger and TriggerStep map to fixed records in sqlite3_fkey_types.bi.
    Case "Trigger", "TriggerStep": Return -1
    ' Pragma metadata and cursors have fixed layouts in sqlite3_pragma_types.bi.
    Case "PragmaName", "PragmaVtab", "PragmaVtabCursor": Return -1
    ' The public vtab headers and private optional-module records are fixed.
    Case "sqlite3_vtab", "sqlite3_vtab_cursor", "KVVfsFile", _
         "sqlite3_kvvfs_methods", "carray_bind", _
         "carray_cursor", "bytecodevtab", "bytecodevtab_cursor", _
         "HiddenIndexInfo": Return -1
    ' SqliteWal mirrors struct Wal, with optional tail fields under matching guards.
    Case "Wal": Return -1
    ' WAL-index headers, checkpoint state, hash locations, and write state are fixed.
    Case "WalIndexHdr", "WalCkptInfo", "WalHashLoc", "WalSegment", "WalWriter": Return -1
    ' WalIterator stores a one-element placeholder for its C flexible segment tail.
    Case "WalIterator": Return -1
    ' TreeView is a fixed debug-only indentation stack.
    Case "TreeView": Return -1
    Case "EncName": Return -1
    ' FuncDef, its final pointer union, and its destructor context are fixed.
    Case "FuncDef", "FuncDef.u", "FuncDestructor": Return -1
    ' IndexedExpr has a fixed linked-list record; optional explain text shares its guard.
    Case "IndexedExpr": Return -1
    ' JSON virtual-table cursor records embed complete JSON parse and string layouts.
    Case "JsonParent", "JsonEachCursor", "JsonEachConnection": Return -1
    ' NameContext is a fixed record with a pointer-sized anonymous union.
    Case "NameContext": Return -1
    ' Returning embeds the fixed Trigger and TriggerStep records.
    Case "Returning", "VtabCtx", "StatTable", "StatCursor", _
         "StatPage", "StatCell": Return -1
    ' RenameCtx is the five-field ALTER TABLE rename callback context.
    Case "RenameCtx": Return -1
    ' IdxCover is the fixed index/cursor context held by Walker callbacks.
    Case "IdxCover": Return -1
    ' DistinctCtx is the fixed four-field state passed to selectInnerLoop.
    Case "DistinctCtx": Return -1
    ' AggInfo and its fixed column/function entries have explicit layouts.
    Case "AggInfo", "AggInfo_col", "AggInfo_func": Return -1
    ' Walker and SELECT scan contexts have fixed pointer, counter, and parent fields.
    Case "RefSrcList", "CheckOnCtx", "SubstContext", "RowLoadInfo", _
         "SortCtx", "DeferredCsr": Return -1
    ' These planner records have fixed storage in the active profile; optional
    ' fields share the feature guards in whereInt.h and sqlite3_where_types.bi.
    Case "CCurHint": Return -1
    ' These planner scratch records and the WhereLoop union have fixed extents.
    ' WhereClause selects the same eight-entry stack array in both layouts;
    ' STAT4 additions to WhereLoopBuilder are guarded in both source trees.
    Case "WhereLevel", "WhereLoop", "WherePath", "WhereRightJoin", _
         "WhereTerm", "WhereClause", "WhereOrCost", "WhereOrSet", "WhereOrInfo", _
         "WhereAndInfo", "WhereLoopBuilder", "WhereLoop.u": Return -1
    ' VDBE sorter records have fixed layouts; VdbeSorter uses one BASIC
    ' placeholder element for its C flexible tail.
    Case "SorterFile", "SorterList", "SorterRecord", "SorterRecord.u", _
         "PmaReader", "MergeEngine", "IncrMerger", "SortSubtask", _
         "PmaWriter", "VdbeSorter": Return -1
    ' MEMSYS3 block headers and allocator state use fixed fields and arrays.
    Case "Mem3Block", "Mem3Block.u", "Mem3Block.u.hdr", _
         "Mem3Block.u.list", "Mem3Global": Return -1
    ' The optional dbpage table and cursor are fixed records with mapped bases.
    Case "DbpageTable", "DbpageCursor": Return -1
    End Select
    Return 0
End Function

Private Function CBodyCandidateUsesFbTypeName( _
    ByVal candidateSource As String, ByVal typeName As String _
) As Long
    If InStr(candidateSource, " As " & typeName) <> 0 OrElse _
       InStr(candidateSource, " As Const " & typeName) <> 0 OrElse _
       InStr(candidateSource, "CPtr(" & typeName) <> 0 OrElse _
       InStr(candidateSource, "CPtr(Const " & typeName) <> 0 Then Return -1
    Return 0
End Function

Private Function FbBodyTypeDeclarationName( _
    ByVal sourceLine As String _
) As String
    Dim lineText As String = Trim(sourceLine)
    Dim loweredLine As String = LCase(lineText)
    If Left(loweredLine, 8) = "private " Then
        lineText = Trim(Mid(lineText, 9))
    ElseIf Left(loweredLine, 7) = "public " Then
        lineText = Trim(Mid(lineText, 8))
    End If
    loweredLine = LCase(lineText)

    Dim keywordLength As Long = 0
    If Left(loweredLine, 5) = "type " Then
        keywordLength = 5
    ElseIf Left(loweredLine, 6) = "union " Then
        keywordLength = 6
    Else
        Return ""
    End If

    Dim position As Long = keywordLength + 1
    Dim nameStart As Long = position
    While position <= Len(lineText) AndAlso _
          IsIdentifierPart(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position = nameStart Then Return ""
    Dim typeName As String = Mid(lineText, nameStart, position - nameStart)
    If LCase(typeName) = "as" Then Return ""
    Return typeName
End Function

Private Function FbBodyIsProcedureDeclaration( _
    ByVal sourceLine As String _
) As Long
    Dim lineText As String = LCase(LTrim(sourceLine))
    If Left(lineText, 8) = "declare " Then Return -1
    Return 0
End Function

Private Sub AddFbBodyDeclaredProcedureName( _
    ByRef procedureNameMap As C2fbStringIndexMapModel, _
    ByRef procedureNameCount As Long, ByVal procedureName As String _
)
    If procedureName = "" Then Exit Sub
    Dim foldedName As String = LCase(procedureName)
    If C2fbStringIndexMapLookup(procedureNameMap, foldedName) >= 0 Then Exit Sub
    If procedureNameCount >= MAX_C2FB_SYMBOLS Then _
        ReportError("FreeBASIC header procedure declarations exceed the configured limit")
    If AddC2fbStringIndexMapEntry( _
        procedureNameMap, foldedName, procedureNameCount) = 0 Then _
        ReportError("FreeBASIC header procedure declaration index exceeds the configured limit")
    procedureNameCount += 1
End Sub

Private Sub AddFbBodySignatureTypeNames( _
    ByRef typeNameMap As C2fbStringIndexMapModel, _
    ByRef typeNameCount As Long, ByVal typeList As String _
)
    Dim typeStart As Long = 1
    For position As Long = 1 To Len(typeList) + 1
        If position <= Len(typeList) AndAlso _
           Mid(typeList, position, 1) <> "|" Then Continue For
        Dim typeName As String = Trim(Mid( _
            typeList, typeStart, position - typeStart))
        typeStart = position + 1
        While Left(LCase(typeName), 6) = "const "
            typeName = Trim(Mid(typeName, 7))
        Wend
        While Right(LCase(typeName), 4) = " ptr"
            typeName = Trim(Left(typeName, Len(typeName) - 4))
        Wend
        If typeName = "" Then Continue For
        Dim isIdentifier As Long = CInt(IsIdentifierStart(Asc(typeName, 1)) <> 0)
        For characterIndex As Long = 2 To Len(typeName)
            If IsIdentifierPart(Asc(typeName, characterIndex)) = 0 Then
                isIdentifier = 0
                Exit For
            End If
        Next
        If isIdentifier = 0 Then Continue For

        Dim foldedName As String = LCase(typeName)
        If C2fbStringIndexMapLookup(typeNameMap, foldedName) >= 0 Then _
            Continue For
        If typeNameCount >= MAX_C2FB_SYMBOLS Then _
            ReportError("called FreeBASIC signature types exceed the configured limit")
        If AddC2fbStringIndexMapEntry( _
            typeNameMap, foldedName, typeNameCount) = 0 Then _
            ReportError("called FreeBASIC signature type index exceeds the configured limit")
        typeNameCount += 1
    Next
End Sub

Private Sub AddFbBodyCalledProcedureNames( _
    ByRef procedureNameMap As C2fbStringIndexMapModel, _
    ByRef procedureNameCount As Long, ByVal sourceText As String _
)
    Dim position As Long = 1
    Dim quoted As Long = 0
    Dim lowerSource As String = LCase(sourceText)
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If currentByte = Asc("""") Then
            quoted = Not quoted
        ElseIf quoted = 0 AndAlso IsIdentifierStart(currentByte) <> 0 Then
            Dim nameStart As Long = position
            position += 1
            While position <= Len(sourceText) AndAlso _
                  IsIdentifierPart(Asc(sourceText, position)) <> 0
                position += 1
            Wend
            Dim procedureName As String = _
                Mid(sourceText, nameStart, position - nameStart)
            Dim followingPosition As Long = position
            While followingPosition <= Len(sourceText) AndAlso _
                  IsSpaceByte(Asc(sourceText, followingPosition)) <> 0
                followingPosition += 1
            Wend
            Dim isProcedureCall As Long = CInt( _
                Mid(sourceText, followingPosition, 1) = "(")
            If isProcedureCall = 0 AndAlso nameStart > 8 AndAlso _
               Mid(lowerSource, nameStart - 8, 8) = "procptr(" AndAlso _
               Mid(sourceText, followingPosition, 1) = ")" Then _
                isProcedureCall = -1
            If isProcedureCall <> 0 Then
                Dim foldedName As String = LCase(procedureName)
                If C2fbStringIndexMapLookup( _
                    procedureNameMap, foldedName) < 0 Then
                    If procedureNameCount >= MAX_C2FB_SYMBOLS Then _
                        ReportError("candidate call names exceed the configured limit")
                    If AddC2fbStringIndexMapEntry( _
                        procedureNameMap, foldedName, procedureNameCount) = 0 Then _
                        ReportError("candidate call-name index exceeds the configured limit")
                    procedureNameCount += 1
                End If
            End If
            Continue While
        End If
        position += 1
    Wend
End Sub

Private Function FbBodyHeaderProviderPriority( _
    ByVal headerName As String _
) As Long
    Dim loweredName As String = LCase(headerName)
    If Right(loweredName, 8) = "_body.bi" Then Return 2
    If InStr(loweredName, "_fts5_") <> 0 Then Return 1
    Return 0
End Function

Private Function FbBodyHeaderTypeLayoutsMatch( _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal ownerName As String, _
    ByVal firstHeader As String, ByVal secondHeader As String _
) As Long
    Dim firstCount As Long = 0
    Dim secondCount As Long = 0
    For fieldIndex As Long = 0 To catalog.bodyFieldCount - 1
        With catalog.bodyFields(fieldIndex)
            If LCase(.ownerName) <> LCase(ownerName) Then Continue For
            If .headerName = firstHeader Then firstCount += 1
            If .headerName = secondHeader Then secondCount += 1
        End With
    Next
    If firstCount = 0 OrElse firstCount <> secondCount Then Return 0
    Dim firstIndexes() As Long
    Dim secondIndexes() As Long
    ReDim firstIndexes(0 To firstCount - 1)
    ReDim secondIndexes(0 To secondCount - 1)
    Dim firstPosition As Long = 0
    Dim secondPosition As Long = 0
    For fieldIndex As Long = 0 To catalog.bodyFieldCount - 1
        With catalog.bodyFields(fieldIndex)
            If LCase(.ownerName) <> LCase(ownerName) Then Continue For
            If .headerName = firstHeader Then
                firstIndexes(firstPosition) = fieldIndex
                firstPosition += 1
            End If
            If .headerName = secondHeader Then
                secondIndexes(secondPosition) = fieldIndex
                secondPosition += 1
            End If
        End With
    Next
    For fieldPosition As Long = 0 To firstCount - 1
        Dim firstIndex As Long = firstIndexes(fieldPosition)
        Dim secondIndex As Long = secondIndexes(fieldPosition)
        With catalog.bodyFields(firstIndex)
            If LCase(.name) <> LCase(catalog.bodyFields(secondIndex).name) OrElse _
               .isArray <> catalog.bodyFields(secondIndex).isArray OrElse _
               .isPrivate <> catalog.bodyFields(secondIndex).isPrivate OrElse _
               LCase(NormalizeFbBodyType(catalog, .typeName)) <> _
               LCase(NormalizeFbBodyType( _
                   catalog, catalog.bodyFields(secondIndex).typeName)) Then Return 0
        End With
    Next
    Return -1
End Function

Private Function FbBodyHeaderHasPreferredTypeProvider( _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal currentHeader As String, ByVal ownerName As String, _
    ByRef providerCache As C2fbStringIndexMapModel _
) As Long
    Dim normalizedTypeName As String = LCase(Trim(ownerName))
    If Left(normalizedTypeName, 6) = "const " Then _
        normalizedTypeName = Mid(normalizedTypeName, 7)
    While Right(normalizedTypeName, 4) = " ptr"
        normalizedTypeName = Left(normalizedTypeName, Len(normalizedTypeName) - 4)
    Wend
    Select Case normalizedTypeName
    Case "c2fb_c_int", "c2fb_c_uint", "c2fb_c_long", "c2fb_c_ulong", _
         "c2fb_int64", "c2fb_uint64", "c2fb_size_t"
        ' Every generated candidate writes target-specific ABI aliases. A
        ' project body header must not become their provider just because it
        ' repeats the alias beside unrelated procedures and record layouts.
        Return -1
    End Select

    Dim resolvedOwnerName As String = _
        ResolveFbBodyRecordOwner(catalog, ownerName)
    If resolvedOwnerName <> "" Then ownerName = resolvedOwnerName
    Dim cacheKey As String = LCase(currentHeader) & Chr(1) & LCase(ownerName)
    Dim cachedValue As Long = C2fbStringIndexMapLookup(providerCache, cacheKey)
    If cachedValue >= 0 Then Return CInt(cachedValue <> 0) * -1

    Dim currentPriority As Long = _
        FbBodyHeaderProviderPriority(currentHeader)
    Dim checkedHeaders As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(checkedHeaders)
    For fieldIndex As Long = 0 To catalog.bodyFieldCount - 1
        With catalog.bodyFields(fieldIndex)
            If LCase(.ownerName) <> LCase(ownerName) OrElse _
               .headerName = "" OrElse .headerName = currentHeader OrElse _
               .headerName = "sqlite3_api_declarations.bi" OrElse _
               .headerName = "sqlite3_internal_api_declarations.bi" Then _
                Continue For
            Dim candidatePriority As Long = _
                FbBodyHeaderProviderPriority(.headerName)
            If candidatePriority > currentPriority OrElse _
               (candidatePriority = currentPriority AndAlso _
                LCase(.headerName) >= LCase(currentHeader)) Then Continue For
            Dim candidateHeader As String = .headerName
            Dim candidateKey As String = LCase(candidateHeader)
            If C2fbStringIndexMapLookup(checkedHeaders, candidateKey) >= 0 Then _
                Continue For
            If AddC2fbStringIndexMapEntry( _
                checkedHeaders, candidateKey, candidatePriority) = 0 Then _
                ReportError("header type-provider set exceeds its configured limit")
            If FbBodyHeaderTypeLayoutsMatch( _
                catalog, ownerName, currentHeader, candidateHeader) <> 0 Then
                If AddC2fbStringIndexMapEntry( _
                    providerCache, cacheKey, 1) = 0 Then _
                    ReportError("body header-provider cache exceeds its configured limit")
                Return -1
            End If
        End With
    Next
    If AddC2fbStringIndexMapEntry(providerCache, cacheKey, 0) = 0 Then _
        ReportError("body header-provider cache exceeds its configured limit")
    Return 0
End Function

Private Function NeedsFbBodyHeader( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal headerName As String, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long, _
    ByRef headerProviderCache As C2fbStringIndexMapModel _
) As Long
    ' Resolve used global object types once before the per-field signature scan.
    For candidateIndex As Long = 0 To candidateCount - 1
        If candidates(candidateIndex).duplicate <> 0 OrElse _
           candidates(candidateIndex).skipMessage <> "" OrElse _
           candidates(candidateIndex).source = "" Then Continue For
        For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
            With translation.body.externalObjects(objectIndex)
                If .isAmbiguous <> 0 OrElse _
                   CBodyUsesIdentifier( _
                       candidates(candidateIndex).source, .freeBasicName) = 0 Then _
                    Continue For
                Dim objectType As String = _
                    NormalizeFbBodyType(catalog, .freeBasicType)
                If Left(objectType, 6) = "Const " Then _
                    objectType = Mid(objectType, 7)
                While Right(objectType, 4) = " Ptr"
                    objectType = Left(objectType, Len(objectType) - 4)
                Wend
                For fieldIndex As Long = 0 To catalog.bodyFieldCount - 1
                    If catalog.bodyFields(fieldIndex).headerName = headerName AndAlso _
                       LCase(catalog.bodyFields(fieldIndex).ownerName) = _
                       LCase(objectType) AndAlso _
                       FbBodyHeaderHasPreferredTypeProvider( _
                           catalog, headerName, objectType, _
                           headerProviderCache) = 0 Then Return -1
                Next
            End With
        Next
    Next

    For candidateIndex As Long = 0 To candidateCount - 1
        If candidates(candidateIndex).duplicate <> 0 OrElse _
           candidates(candidateIndex).skipMessage <> "" OrElse _
           candidates(candidateIndex).source = "" Then Continue For
        For fieldIndex As Long = 0 To catalog.bodyFieldCount - 1
            If catalog.bodyFields(fieldIndex).headerName <> headerName Then Continue For
            Dim typeName As String = catalog.bodyFields(fieldIndex).ownerName
            If FbBodyHeaderHasPreferredTypeProvider( _
                catalog, headerName, typeName, headerProviderCache) = 0 AndAlso _
               CBodyCandidateUsesFbTypeName( _
                   candidates(candidateIndex).source, typeName) <> 0 Then Return -1
        Next

        ' Test each referenced type alias once, then match its resolved record
        ' against the fields in this header. Resolving aliases inside the field
        ' loop multiplied the cost by both the field and alias counts.
        For aliasIndex As Long = 0 To catalog.bodyTypeAliasCount - 1
            Dim aliasName As String = catalog.bodyTypeAliases(aliasIndex).aliasName
            If CBodyCandidateUsesFbTypeName( _
                candidates(candidateIndex).source, aliasName) <> 0 Then
                Dim typeName As String = ResolveFbBodyRecordAlias(catalog, aliasName)
                For fieldIndex As Long = 0 To catalog.bodyFieldCount - 1
                    If catalog.bodyFields(fieldIndex).headerName = headerName AndAlso _
                       LCase(catalog.bodyFields(fieldIndex).ownerName) = LCase(typeName) Then _
                        If FbBodyHeaderHasPreferredTypeProvider( _
                            catalog, headerName, typeName, _
                            headerProviderCache) = 0 Then Return -1
                Next
            End If
        Next
    Next
    Return 0
End Function

Private Sub ResetC2fbFbLayoutCatalog(ByRef catalog As C2fbProjectCatalog)
    ReDim catalog.bodyFields(0 To 255)
    catalog.bodyFieldCount = 0
    ResetC2fbStringIndexMap(catalog.bodyRecordOwnerMap)
    ResetC2fbStringIndexMap(catalog.bodyPublicRecordOwnerMap)
    ResetC2fbStringIndexMap(catalog.bodyPublicRecordOwnerExactMap)
    ResetC2fbStringIndexMap(catalog.bodyFieldIndex)
    ReDim catalog.bodyTypeAliases(0 To 63)
    catalog.bodyTypeAliasCount = 0
    ResetC2fbStringIndexMap(catalog.bodyTypeAliasMap)
End Sub

Private Sub ResetC2fbFbLayoutFile( _
    ByRef state As C2fbFbLayoutScanStateModel _
)
    state.typeDepth = 0
    For index As Long = 0 To MAX_C2FB_FB_LAYOUT_NESTING - 1
        state.typeNames(index) = ""
        state.typePrivate(index) = 0
        state.typeIsUnion(index) = 0
    Next
End Sub

Private Function FreeBasicBodyFieldArrayCount( _
    ByVal sourceBounds As String _
) As Long
    Dim dimensions() As String
    Dim dimensionCount As Long
    If SplitSimpleCList( _
        sourceBounds, dimensions(), dimensionCount) = 0 OrElse _
       dimensionCount < 1 OrElse _
       dimensionCount > MAX_GENERIC_ARRAY_RANK Then Return 0

    Dim totalCount As LongInt = 1
    For dimensionIndex As Long = 0 To dimensionCount - 1
        Dim rangePosition As Long = InStr(LCase(dimensions(dimensionIndex)), " to ")
        Dim lowerBound As Long = 0
        Dim upperBound As Long
        If rangePosition > 0 Then
            If EvaluateSimpleArrayBound( _
                Trim(Left(dimensions(dimensionIndex), rangePosition - 1)), _
                lowerBound, MAX_GENERIC_ARRAY_COUNT, -1) = 0 OrElse _
               EvaluateSimpleArrayBound( _
                Trim(Mid(dimensions(dimensionIndex), rangePosition + 4)), _
                upperBound, MAX_GENERIC_ARRAY_COUNT, -1) = 0 OrElse _
               upperBound < lowerBound Then Return 0
            upperBound = upperBound - lowerBound
        ElseIf EvaluateSimpleArrayBound( _
            Trim(dimensions(dimensionIndex)), upperBound, _
            MAX_GENERIC_ARRAY_COUNT, -1) <> 0 Then
            lowerBound = 0
        Else
            Return 0
        End If

        Dim extent As LongInt = CLngInt(upperBound) + 1
        If extent <= 0 OrElse _
           totalCount > MAX_GENERIC_ARRAY_COUNT \ extent Then Return 0
        totalCount *= extent
    Next
    Return CLng(totalCount)
End Function

Private Sub IndexC2fbFbLayoutLine( _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef state As C2fbFbLayoutScanStateModel, _
    ByVal fileName As String, ByVal sourceLine As String _
)
    Dim lineText As String = Trim(sourceLine)
    Dim lowered As String = LCase(lineText)
    Dim declarationIsPrivate As Long = 0
    If Left(lowered, 8) = "private " Then
        declarationIsPrivate = -1
        lineText = Trim(Mid(lineText, 9))
    ElseIf Left(lowered, 7) = "public " Then
        lineText = Trim(Mid(lineText, 8))
    End If
    lowered = LCase(lineText)
    If lowered = "end type" OrElse lowered = "end union" Then
        If state.typeDepth > 0 Then
            state.typeDepth -= 1
            state.typeNames(state.typeDepth) = ""
            state.typePrivate(state.typeDepth) = 0
            state.typeIsUnion(state.typeDepth) = 0
        End If
        Exit Sub
    End If

    Dim recordFieldUsesTypeKeyword As Long = 0
    If state.typeDepth > 0 Then
        Dim typeKeywordLength As Long = 0
        If Left(lowered, 5) = "type " Then
            typeKeywordLength = 5
        ElseIf Left(lowered, 6) = "union " Then
            typeKeywordLength = 6
        End If
        If typeKeywordLength > 0 Then
            Dim afterTypeKeyword As String = LCase(LTrim(Mid(lineText, typeKeywordLength + 1)))
            ' Type and Union can also be field names. A bitfield or array
            ' declarator places its colon or opening parenthesis before As.
            If Left(afterTypeKeyword, 3) = "as " OrElse _
               Left(afterTypeKeyword, 1) = ":" OrElse _
               Left(afterTypeKeyword, 1) = "(" Then _
                recordFieldUsesTypeKeyword = -1
        End If
    End If
    If (Left(lowered, 5) = "type " OrElse lowered = "type" OrElse _
        Left(lowered, 6) = "union " OrElse lowered = "union") AndAlso _
       recordFieldUsesTypeKeyword = 0 Then
        If state.typeDepth > 0 AndAlso _
           state.typePrivate(state.typeDepth - 1) <> 0 Then _
            declarationIsPrivate = -1
        Dim position As Long = IIf(Left(lowered, 5) = "type ", 6, 7)
        Dim start As Long = position
        While position <= Len(lineText) AndAlso _
              IsIdentifierPart(Asc(lineText, position)) <> 0
            position += 1
        Wend
        Dim owner As String = Mid(lineText, start, position - start)
        If Left(LCase(LTrim(Mid(lineText, position))), 3) = "as " Then
            Dim targetName As String = Trim(Mid(lineText, position + 3))
            Dim commentPosition As Long = InStr(targetName, "'")
            If commentPosition > 0 Then _
                targetName = RTrim(Left(targetName, commentPosition - 1))
            If owner <> "" AndAlso _
               IsSimpleFbTypeAliasTarget(targetName) <> 0 Then
                Dim foldedOwner As String = LCase(owner)
                Dim aliasIndex As Long = C2fbStringIndexMapLookup( _
                    catalog.bodyTypeAliasMap, foldedOwner)
                If aliasIndex >= 0 AndAlso _
                   aliasIndex < catalog.bodyTypeAliasCount Then
                    catalog.bodyTypeAliases(aliasIndex).targetName = targetName
                    catalog.bodyTypeAliases(aliasIndex).isPrivate = _
                        declarationIsPrivate
                Else
                    ' SDK type indexes can exceed the function-work limit.
                    If catalog.bodyTypeAliasCount >= _
                       MAX_C2FB_BODY_TYPE_ALIASES Then _
                        ReportError("port type aliases exceed the configured limit")
                    If catalog.bodyTypeAliasCount > UBound(catalog.bodyTypeAliases) Then _
                        ReDim Preserve catalog.bodyTypeAliases( _
                            0 To UBound(catalog.bodyTypeAliases) * 2 + 1)
                    aliasIndex = catalog.bodyTypeAliasCount
                    catalog.bodyTypeAliases( _
                        aliasIndex).aliasName = owner
                    catalog.bodyTypeAliases( _
                        aliasIndex).targetName = targetName
                    catalog.bodyTypeAliases( _
                        aliasIndex).isPrivate = declarationIsPrivate
                    catalog.bodyTypeAliasCount += 1
                    If AddC2fbStringIndexMapEntry( _
                        catalog.bodyTypeAliasMap, foldedOwner, aliasIndex) = 0 Then _
                        ReportError("port type-alias index exceeds the configured limit")
                End If
            End If
            Exit Sub
        End If
        If owner = "" AndAlso state.typeDepth > 0 Then _
            owner = state.typeNames(state.typeDepth - 1)
        If owner = "" Then Exit Sub
        If state.typeDepth >= MAX_C2FB_FB_LAYOUT_NESTING Then _
            ReportError("port layout nesting exceeds the configured limit")
        state.typeNames(state.typeDepth) = owner
        state.typePrivate(state.typeDepth) = declarationIsPrivate
        state.typeIsUnion(state.typeDepth) = CInt( _
            lowered = "union" OrElse Left(lowered, 6) = "union ")
        state.typeDepth += 1
        Exit Sub
    End If

    If state.typeDepth = 0 OrElse lineText = "" OrElse _
       IsIdentifierStart(Asc(lineText, 1)) = 0 Then Exit Sub
    Dim position As Long = 1
    While position <= Len(lineText) AndAlso _
          IsIdentifierPart(Asc(lineText, position)) <> 0
        position += 1
    Wend
    Dim fieldName As String = Left(lineText, position - 1)
    Dim isArray As Long = 0
    Dim arrayCount As Long = 0
    SkipCSpaces(lineText, position)
    If Mid(lineText, position, 1) = "(" Then
        Dim arrayBoundsStart As Long = position + 1
        Dim arrayBoundsEnd As Long = position
        If ScanSimpleExpressionGroup( _
            lineText, arrayBoundsEnd, Asc("("), Asc(")")) = 0 Then Exit Sub
        arrayCount = FreeBasicBodyFieldArrayCount(Trim(Mid( _
            lineText, arrayBoundsStart, _
            arrayBoundsEnd - arrayBoundsStart - 1)))
        position = arrayBoundsEnd
        isArray = -1
        SkipCSpaces(lineText, position)
    End If
    If Mid(lineText, position, 1) = ":" Then
        ' FreeBASIC records expose bitfields as named fields with an explicit
        ' width before As. The C declaration remains authoritative for the
        ' width and signedness; this index only needs the field's storage type.
        position += 1
        SkipCSpaces(lineText, position)
        Dim widthStart As Long = position
        While position <= Len(lineText) AndAlso _
              Asc(lineText, position) >= Asc("0") AndAlso _
              Asc(lineText, position) <= Asc("9")
            position += 1
        Wend
        If position = widthStart Then Exit Sub
        SkipCSpaces(lineText, position)
    End If
    If LCase(Mid(lineText, position, 3)) <> "as " Then Exit Sub
    Dim typeName As String = Trim(Mid(lineText, position + 3))
    Dim commentPosition As Long = InStr(typeName, "'")
    If commentPosition > 0 Then _
        typeName = RTrim(Left(typeName, commentPosition - 1))
    If typeName = "" Then Exit Sub
    If catalog.bodyFieldCount >= MAX_C2FB_BODY_CATALOG_FIELDS Then _
        ReportError("port layouts exceed the configured field limit")
    If catalog.bodyFieldCount > UBound(catalog.bodyFields) Then _
        ReDim Preserve catalog.bodyFields( _
            0 To UBound(catalog.bodyFields) * 2 + 1)
    With catalog.bodyFields(catalog.bodyFieldCount)
        .ownerName = state.typeNames(state.typeDepth - 1)
        .name = fieldName
        .typeName = typeName
        .isArray = isArray
        .arrayCount = arrayCount
        .isUnionMember = state.typeIsUnion(state.typeDepth - 1)
        .isPrivate = state.typePrivate(state.typeDepth - 1)
        .headerName = fileName
    End With
    catalog.bodyFieldCount += 1
    IndexC2fbBodyField(catalog, catalog.bodyFieldCount - 1)
    Dim ownerName As String = state.typeNames(state.typeDepth - 1)
    Dim ownerKey As String = LCase(ownerName)
    If C2fbStringIndexMapLookup( _
        catalog.bodyRecordOwnerMap, ownerKey) < 0 Then
        If AddC2fbStringIndexMapEntry( _
            catalog.bodyRecordOwnerMap, ownerKey, _
            catalog.bodyFieldCount - 1) = 0 Then _
            ReportError("port record-layout index exceeds the configured limit")
    End If
End Sub

/' end of c2fb_layouts.bi '/
