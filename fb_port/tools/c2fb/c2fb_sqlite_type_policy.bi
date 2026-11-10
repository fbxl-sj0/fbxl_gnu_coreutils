/'
    Project: C2FB SQLite type policy

    File: c2fb_sqlite_type_policy.bi

    Purpose:

        Identify C names whose body mapping depends on the SQLite port model.

    Responsibilities:

        - Classify SQLite internal types and ABI aliases for body resolution.
        - Let generic body mapping look up caller-provided aliases or records.

    This file intentionally does NOT contain:

        - C type syntax parsing or general target mapping.
        - SQLite header declarations, source collection, or output formatting.
'/

Private Function IsSQLiteBodySpecificType(ByVal typeName As String) As Long
    Select Case typeName
    Case "sqlite3_callback", "sqlite3_destructor_type", "sqlite3_syscall_ptr", _
         "sqlite3_filename", "Token", "sqlite3", "Btree", "BtShared", _
         "BtCursor", "MemPage", "CellInfo", "Pager", "PgHdr", "Hash", _
         "HashElem", "HashBucket", "Vdbe", "sqlite3_stmt", "Mem", "Expr", _
         "ExprList", "ExprList_item", "IdList_item", "Select", "Parse", _
         "LogEst", "Bitmask", _
         "sqlite3_int64", "sqlite_int64", "sqlite3_uint64", _
         "SQLITE_C_INT", "SQLITE_C_UINT", "SQLITE_C_LONG", "SQLITE_C_ULONG", _
         "SQLITE_SIZE_T"
        Return -1
    End Select
    Return 0
End Function

/' end of c2fb_sqlite_type_policy.bi '/
