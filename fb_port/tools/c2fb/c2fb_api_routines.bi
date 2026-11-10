/'
    Project: C2FB SQLite API table adapter
    --------------------------------------

    File: c2fb_api_routines.bi

    Purpose:

        Generate SQLite's FreeBASIC extension API pointer table from
        preprocessed source and the function-porting ledger.

    Responsibilities:

        - Validate the C struct and initializer slot counts.
        - Use the shared CSV model to select implemented API functions.
        - Emit declarations and the pointer table through shared output models.
        - Return a typed result or an error to the command frontend.

    This file intentionally does NOT contain:

        - Command-line parsing or standalone executable behavior.
        - General C declaration or expression translation.
'/

Private Function readWholeFile(ByVal path As String) As String
    Dim contents As String
    If ReadC2fbWholeBinaryFile(path, contents) = 0 Then Return ""
    Return contents
End Function

Private Function apiBodyAliasFromLine(ByVal sourceLine As String) As String
    Dim lineText As String = LTrim(sourceLine)
    If lineText = "" OrElse Left(lineText, 1) = "#" OrElse _
       Left(lineText, 1) = "'" OrElse Left(lineText, 2) = "/'" Then Return ""
    Dim loweredLine As String = LCase(lineText)
    If Left(loweredLine, 8) = "private " OrElse _
       Left(loweredLine, 7) = "static " Then Return ""
    If Left(loweredLine, 7) = "public " Then
        lineText = LTrim(Mid(lineText, 8))
        loweredLine = LCase(lineText)
    End If
    If Left(loweredLine, 9) <> "function " AndAlso _
       Left(loweredLine, 4) <> "sub " Then Return ""

    Dim aliasPosition As Long = InStr(loweredLine, " alias ")
    If aliasPosition = 0 Then Return ""
    Dim position As Long = aliasPosition + Len(" alias ")
    If position > Len(lineText) OrElse _
       Asc(lineText, position) <> Asc(Chr(34)) Then Return ""
    position += 1
    Dim aliasStart As Long = position
    While position <= Len(lineText) AndAlso _
          Asc(lineText, position) <> Asc(Chr(34))
        position += 1
    Wend
    If position <= aliasStart OrElse position > Len(lineText) Then Return ""
    Return Mid(lineText, aliasStart, position - aliasStart)
End Function

Private Function readFreeBasicApiBodyNames( _
    ByRef sourceDirectory As String, ByRef bodyNames As String _
) As Long
    bodyNames = "|"
    Dim fileName As String = Dir(sourceDirectory & "*.bas")
    While fileName <> ""
        Dim fileText As String = readWholeFile(sourceDirectory & fileName)
        Dim lineStart As Long = 1
        While lineStart <= Len(fileText)
            Dim lineEnd As Long = InStr(lineStart, fileText, Chr(10))
            If lineEnd = 0 Then lineEnd = Len(fileText) + 1
            Dim aliasName As String = apiBodyAliasFromLine( _
                Mid(fileText, lineStart, lineEnd - lineStart))
            If aliasName <> "" AndAlso _
               InStr(bodyNames, "|" & aliasName & "|") = 0 Then
                bodyNames &= aliasName & "|"
            End If
            lineStart = lineEnd + 1
        Wend
        fileName = Dir()
    Wend
    Return -1
End Function


Private Function readPortedApiNames( _
    ByRef csvText As String, ByRef bodyNames As String, _
    ByRef portedNames As String, _
    ByRef errorMessage As String _
) As Long
    portedNames = "|"
    errorMessage = ""
    Dim lineStart As Long = 1
    While lineStart <= Len(csvText)
        Dim lineEnd As Long = InStr(lineStart, csvText, Chr(10))
        If lineEnd = 0 Then lineEnd = Len(csvText) + 1
        Dim lineText As String = Trim(Mid(csvText, lineStart, lineEnd - lineStart))
        If lineText <> "" Then
            Dim row As C2fbCsvRowModel
            If ParseC2fbCsvRow(lineText, row, errorMessage) = 0 Then
                errorMessage = "invalid porting-function CSV row: " & errorMessage
                Return 0
            End If
            If row.fieldCount < 7 Then
                errorMessage = "porting-function CSV row has fewer than seven fields"
                Return 0
            End If
            Dim functionName As String = row.fields(1).value
            Dim portStatus As String = row.fields(6).value
            If portStatus = "FB body present" AndAlso Left(functionName, 8) = "sqlite3_" Then
                portedNames &= functionName & "|"
            End If
        End If
        lineStart = lineEnd + 1
    Wend
    portedNames &= bodyNames
    Return -1
End Function

Private Function countApiStructFields(ByRef source As String) As Long
    Dim marker As Long = InStr(source, "struct sqlite3_api_routines {")
    If marker = 0 Then Return 0
    Dim openBrace As Long = marker + Len("struct sqlite3_api_routines ")
    Dim parentheses As Long = 0
    Dim fieldCount As Long = 0
    For position As Long = openBrace + 1 To Len(source)
        Dim character As String = Mid(source, position, 1)
        Select Case character
        Case "("
            parentheses += 1
        Case ")"
            If parentheses > 0 Then parentheses -= 1
        Case ";"
            If parentheses = 0 Then fieldCount += 1
        Case "}"
            Return fieldCount
        End Select
    Next
    Return 0
End Function

Private Function collectApiEntries( _
    ByRef source As String, _
    entries() As String _
) As Long
    Dim marker As Long = InStr(source, "static const sqlite3_api_routines sqlite3Apis")
    If marker = 0 Then Return 0
    Dim openBrace As Long = InStr(marker, source, "{")
    If openBrace = 0 Then Return 0

    Dim entryCount As Long = 0
    Dim entryStart As Long = openBrace + 1
    Dim braceDepth As Long = 1
    Dim parenthesisDepth As Long = 0
    Dim inString As Long = 0
    Dim inCharacter As Long = 0
    Dim escaped As Long = 0
    ReDim entries(0 To 0)

    For position As Long = openBrace + 1 To Len(source)
        Dim character As String = Mid(source, position, 1)
        If inString <> 0 OrElse inCharacter <> 0 Then
            If escaped <> 0 Then
                escaped = 0
            ElseIf character = Chr(92) Then
                escaped = 1
            ElseIf inString <> 0 AndAlso character = Chr(34) Then
                inString = 0
            ElseIf inCharacter <> 0 AndAlso character = Chr(39) Then
                inCharacter = 0
            End If
            Continue For
        End If

        If character = Chr(34) Then
            inString = 1
        ElseIf character = Chr(39) Then
            inCharacter = 1
        ElseIf character = "(" Then
            parenthesisDepth += 1
        ElseIf character = ")" Then
            If parenthesisDepth > 0 Then parenthesisDepth -= 1
        ElseIf character = "{" Then
            braceDepth += 1
        ElseIf character = "}" Then
            braceDepth -= 1
            If braceDepth = 0 Then
                Dim finalEntry As String = Trim(Mid(source, entryStart, position - entryStart))
                If Len(finalEntry) > 0 Then
                    If entryCount > 0 Then ReDim Preserve entries(0 To entryCount)
                    entries(entryCount) = finalEntry
                    entryCount += 1
                End If
                Return entryCount
            End If
        ElseIf character = "," AndAlso braceDepth = 1 AndAlso parenthesisDepth = 0 Then
            Dim entry As String = Trim(Mid(source, entryStart, position - entryStart))
            If Len(entry) = 0 Then Return 0
            If entryCount > 0 Then ReDim Preserve entries(0 To entryCount)
            entries(entryCount) = entry
            entryCount += 1
            entryStart = position + 1
        End If
    Next
    Return 0
End Function

Private Function apiNameFromEntry(ByRef entry As String) As String
    If entry = "0" OrElse UCase(entry) = "NULL" Then Return ""
    Dim lastApiName As String
    Dim position As Long = 1
    While position <= Len(entry)
        Dim character As String = Mid(entry, position, 1)
        If (character >= "A" AndAlso character <= "Z") OrElse _
           (character >= "a" AndAlso character <= "z") OrElse character = "_" Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(entry)
                character = Mid(entry, position, 1)
                If (character >= "A" AndAlso character <= "Z") OrElse _
                   (character >= "a" AndAlso character <= "z") OrElse _
                   (character >= "0" AndAlso character <= "9") OrElse character = "_" Then
                    position += 1
                Else
                    Exit While
                End If
            Wend
            Dim token As String = Mid(entry, tokenStart, position - tokenStart)
            If Left(token, 8) = "sqlite3_" Then lastApiName = token
        Else
            position += 1
        End If
    Wend
    Return lastApiName
End Function

' These append-only sqlite3ext.h slots remain in the ABI when their optional
' features are disabled; loadext.c fills them with NULL in those profiles.
Private Function optionalApiNameForSlot(ByVal apiSlot As Long) As String
    Select Case apiSlot
    Case 1
        Return "sqlite3_aggregate_count"
    Case 11
        Return "sqlite3_bind_text16"
    Case 18
        Return "sqlite3_collation_needed16"
    Case 23
        Return "sqlite3_column_database_name"
    Case 24
        Return "sqlite3_column_database_name16"
    Case 25
        Return "sqlite3_column_decltype"
    Case 26
        Return "sqlite3_column_decltype16"
    Case 31
        Return "sqlite3_column_name16"
    Case 32
        Return "sqlite3_column_origin_name"
    Case 33
        Return "sqlite3_column_origin_name16"
    Case 34
        Return "sqlite3_column_table_name"
    Case 35
        Return "sqlite3_column_table_name16"
    Case 37
        Return "sqlite3_column_text16"
    Case 41
        Return "sqlite3_complete"
    Case 42
        Return "sqlite3_complete16"
    Case 44
        Return "sqlite3_create_collation16"
    Case 46
        Return "sqlite3_create_function16"
    Case 47
        Return "sqlite3_create_module"
    Case 50
        Return "sqlite3_declare_vtab"
    Case 51
        Return "sqlite3_enable_shared_cache"
    Case 54
        Return "sqlite3_errmsg16"
    Case 56
        Return "sqlite3_expired"
    Case 59
        Return "sqlite3_free_table"
    Case 62
        Return "sqlite3_get_table"
    Case 71
        Return "sqlite3_open16"
    Case 73
        Return "sqlite3_prepare16"
    Case 74
        Return "sqlite3_profile"
    Case 75
        Return "sqlite3_progress_handler"
    Case 81
        Return "sqlite3_result_error16"
    Case 86
        Return "sqlite3_result_text16"
    Case 87
        Return "sqlite3_result_text16be"
    Case 88
        Return "sqlite3_result_text16le"
    Case 91
        Return "sqlite3_set_authorizer"
    Case 96
        Return "sqlite3_thread_cleanup"
    Case 98
        Return "sqlite3_trace"
    Case 99
        Return "sqlite3_transfer_bindings"
    Case 110
        Return "sqlite3_value_text16"
    Case 111
        Return "sqlite3_value_text16be"
    Case 112
        Return "sqlite3_value_text16le"
    Case 117
        Return "sqlite3_prepare16_v2"
    Case 119
        Return "sqlite3_create_module_v2"
    Case 120
        Return "sqlite3_bind_zeroblob"
    Case 121
        Return "sqlite3_blob_bytes"
    Case 122
        Return "sqlite3_blob_close"
    Case 123
        Return "sqlite3_blob_open"
    Case 124
        Return "sqlite3_blob_read"
    Case 125
        Return "sqlite3_blob_write"
    Case 130
        Return "sqlite3_mutex_alloc"
    Case 131
        Return "sqlite3_mutex_enter"
    Case 132
        Return "sqlite3_mutex_free"
    Case 133
        Return "sqlite3_mutex_leave"
    Case 134
        Return "sqlite3_mutex_try"
    Case 160
        Return "sqlite3_compileoption_get"
    Case 161
        Return "sqlite3_compileoption_used"
    Case 172
        Return "sqlite3_unlock_notify"
    Case 173
        Return "sqlite3_wal_autocheckpoint"
    Case 174
        Return "sqlite3_wal_checkpoint"
    Case 175
        Return "sqlite3_wal_hook"
    Case 176
        Return "sqlite3_blob_reopen"
    Case 177
        Return "sqlite3_vtab_config"
    Case 178
        Return "sqlite3_vtab_on_conflict"
    Case 191
        Return "sqlite3_wal_checkpoint_v2"
    Case 214
        Return "sqlite3_trace_v2"
    Case 218
        Return "sqlite3_prepare16_v3"
    Case 224
        Return "sqlite3_vtab_collation"
    Case 240
        Return "sqlite3_normalized_sql"
    Case 243
        Return "sqlite3_drop_modules"
    Case 257
        Return "sqlite3_vtab_rhs_value"
    Case 258
        Return "sqlite3_vtab_distinct"
    Case 259
        Return "sqlite3_vtab_in"
    Case 260
        Return "sqlite3_vtab_in_first"
    Case 261
        Return "sqlite3_vtab_in_next"
    Case 262
        Return "sqlite3_deserialize"
    Case 263
        Return "sqlite3_serialize"
    Case 275
        Return "sqlite3_carray_bind"
    Case 276
        Return "sqlite3_carray_bind_v2"
    End Select
    Return ""
End Function

Private Function optionalApiGuard(ByRef apiName As String) As String
    Select Case apiName
    Case "sqlite3_aggregate_count", "sqlite3_expired", _
         "sqlite3_thread_cleanup", "sqlite3_transfer_bindings"
        Return "#ifndef SQLITE_OMIT_DEPRECATED"
    Case "sqlite3_bind_text16", "sqlite3_collation_needed16", _
         "sqlite3_column_name16", "sqlite3_column_text16", _
         "sqlite3_create_collation16", "sqlite3_create_function16", _
         "sqlite3_errmsg16", "sqlite3_open16", "sqlite3_prepare16", _
         "sqlite3_prepare16_v2", "sqlite3_prepare16_v3", _
         "sqlite3_result_error16", "sqlite3_result_text16", _
         "sqlite3_result_text16be", "sqlite3_result_text16le", _
         "sqlite3_value_text16", "sqlite3_value_text16be", _
         "sqlite3_value_text16le"
        Return "#ifndef SQLITE_OMIT_UTF16"
    Case "sqlite3_column_database_name", "sqlite3_column_origin_name", _
         "sqlite3_column_table_name"
        Return "#ifdef SQLITE_ENABLE_COLUMN_METADATA"
    Case "sqlite3_column_database_name16", "sqlite3_column_origin_name16", _
         "sqlite3_column_table_name16"
        Return "#if defined(SQLITE_ENABLE_COLUMN_METADATA) AndAlso Not defined(SQLITE_OMIT_UTF16)"
    Case "sqlite3_column_decltype"
        Return "#ifndef SQLITE_OMIT_DECLTYPE"
    Case "sqlite3_column_decltype16"
        Return "#if Not defined(SQLITE_OMIT_DECLTYPE) AndAlso Not defined(SQLITE_OMIT_UTF16)"
    Case "sqlite3_complete"
        Return "#ifndef SQLITE_OMIT_COMPLETE"
    Case "sqlite3_complete16"
        Return "#if Not defined(SQLITE_OMIT_COMPLETE) AndAlso Not defined(SQLITE_OMIT_UTF16)"
    Case "sqlite3_create_module", "sqlite3_create_module_v2", _
         "sqlite3_declare_vtab", "sqlite3_drop_modules", _
         "sqlite3_vtab_config", "sqlite3_vtab_on_conflict", _
         "sqlite3_vtab_collation", "sqlite3_vtab_rhs_value", _
         "sqlite3_vtab_distinct", "sqlite3_vtab_in", _
         "sqlite3_vtab_in_first", "sqlite3_vtab_in_next"
        Return "#ifndef SQLITE_OMIT_VIRTUALTABLE"
    Case "sqlite3_enable_shared_cache"
        Return "#ifndef SQLITE_OMIT_SHARED_CACHE"
    Case "sqlite3_free_table", "sqlite3_get_table"
        Return "#ifndef SQLITE_OMIT_GET_TABLE"
    Case "sqlite3_progress_handler"
        Return "#ifndef SQLITE_OMIT_PROGRESS_CALLBACK"
    Case "sqlite3_set_authorizer"
        Return "#ifndef SQLITE_OMIT_AUTHORIZATION"
    Case "sqlite3_profile", "sqlite3_trace"
        Return "#if Not defined(SQLITE_OMIT_TRACE) AndAlso Not defined(SQLITE_OMIT_DEPRECATED)"
    Case "sqlite3_trace_v2"
        Return "#ifndef SQLITE_OMIT_TRACE"
    Case "sqlite3_bind_zeroblob", "sqlite3_blob_bytes", _
         "sqlite3_blob_close", "sqlite3_blob_open", "sqlite3_blob_read", _
         "sqlite3_blob_reopen", "sqlite3_blob_write"
        Return "#ifndef SQLITE_OMIT_INCRBLOB"
    Case "sqlite3_mutex_alloc", "sqlite3_mutex_enter", "sqlite3_mutex_free", _
         "sqlite3_mutex_leave", "sqlite3_mutex_try"
        Return "#ifndef SQLITE_MUTEX_OMIT"
    Case "sqlite3_compileoption_get", "sqlite3_compileoption_used"
        Return "#ifndef SQLITE_OMIT_COMPILEOPTION_DIAGS"
    Case "sqlite3_wal_autocheckpoint", "sqlite3_wal_checkpoint", _
         "sqlite3_wal_hook", "sqlite3_wal_checkpoint_v2"
        Return "#ifndef SQLITE_OMIT_WAL"
    Case "sqlite3_unlock_notify"
        Return "#ifdef SQLITE_ENABLE_UNLOCK_NOTIFY"
    Case "sqlite3_normalized_sql"
        Return "#ifdef SQLITE_ENABLE_NORMALIZE"
    Case "sqlite3_carray_bind", "sqlite3_carray_bind_v2"
        Return "#if defined(SQLITE_ENABLE_CARRAY) AndAlso Not defined(SQLITE_OMIT_VIRTUALTABLE)"
    End Select
    Return ""
End Function

Private Function parentDirectory(ByRef path As String) As String
    For position As Long = Len(path) To 1 Step -1
        If Mid(path, position, 1) = "/" Then Return Left(path, position)
    Next
    Return "./"
End Function

Private Type VisitedPathList
    count As Long
    paths(0 To 255) As String
End Type

Private Function pathWasVisited( _
    ByRef path As String, _
    ByVal pVisited As VisitedPathList Ptr _
) As Long
    If pVisited = 0 Then Return 0
    For index As Long = 0 To pVisited->count - 1
        If pVisited->paths(index) = path Then Return 1
    Next
    Return 0
End Function

Private Function fileTreeHasApiDeclaration( _
    ByRef path As String, _
    ByRef sourceDirectory As String, _
    ByRef apiName As String, _
    ByRef generatedOutputPath As String, _
    ByVal pVisited As VisitedPathList Ptr, _
    ByVal depth As Long _
) As Long
    If pVisited = 0 OrElse depth > 32 OrElse _
       pVisited->count >= 256 OrElse pathWasVisited(path, pVisited) <> 0 Then Return 0

    ' The owner always includes this table by its stable name, even when a
    ' caller writes a temporary profile-specific table to a build directory.
    ' Do not treat declarations in the checked-in table as independent inputs.
    If path = generatedOutputPath OrElse _
       path = sourceDirectory & generatedOutputPath OrElse _
       path = sourceDirectory & "sqlite3_extension_api_table.bi" Then Return 0

    pVisited->paths(pVisited->count) = path
    pVisited->count += 1

    Dim fileText As String = readWholeFile(path)
    If fileText = "" Then Return 0
    Dim aliasText As String = "Alias " & Chr(34) & apiName & Chr(34)
    If InStr(fileText, aliasText) <> 0 Then Return 1

    Dim lineStart As Long = 1
    While lineStart <= Len(fileText)
        Dim lineEnd As Long = InStr(lineStart, fileText, Chr(10))
        If lineEnd = 0 Then lineEnd = Len(fileText) + 1
        Dim lineText As String = LTrim(Mid(fileText, lineStart, lineEnd - lineStart))
        If Left(lineText, 8) = "#include" Then
            Dim quoteStart As Long = InStr(lineText, Chr(34))
            If quoteStart <> 0 Then
                Dim quoteEnd As Long = InStr(quoteStart + 1, lineText, Chr(34))
                If quoteEnd > quoteStart Then
                    Dim includePath As String = sourceDirectory & _
                        Mid(lineText, quoteStart + 1, quoteEnd - quoteStart - 1)
                    If fileTreeHasApiDeclaration( _
                        includePath, sourceDirectory, apiName, generatedOutputPath, _
                        pVisited, depth + 1) <> 0 Then Return 1
                End If
            End If
        End If
        lineStart = lineEnd + 1
    Wend
    Return 0
End Function

Private Function ownerHasApiDeclaration( _
    ByRef modulePath As String, _
    ByRef sourceDirectory As String, _
    ByRef apiName As String, _
    ByRef generatedOutputPath As String _
) As Long
    Dim visited As VisitedPathList
    Return fileTreeHasApiDeclaration( _
        modulePath, sourceDirectory, apiName, generatedOutputPath, @visited, 0)
End Function

Private Function ownerModuleTextDeclaresApi( _
    ByRef moduleText As String, _
    ByRef apiName As String _
) As Long
    Dim aliasText As String = "Alias " & Chr(34) & apiName & Chr(34)
    Return IIf(InStr(moduleText, aliasText) <> 0, 1, 0)
End Function

Private Function ConvertC2fbApiRoutines( _
    ByRef request As C2fbApiRoutinesRequestModel, _
    ByRef result As C2fbApiRoutinesResultModel, _
    ByRef errorMessage As String _
) As Long
    errorMessage = ""
    result.entryCount = 0
    result.portedCount = 0
    Dim inputPath As String = request.preprocessedInputPath
    Dim portingCsvPath As String = request.functionLedgerPath
    Dim modulePath As String = request.ownerModulePath
    Dim outputPath As String = request.outputPath

    Dim source As String = readWholeFile(inputPath)
    Dim csvText As String = readWholeFile(portingCsvPath)
    Dim ownerText As String = readWholeFile(modulePath)
    If source = "" OrElse csvText = "" OrElse ownerText = "" Then
        errorMessage = "unable to read an input file"
        Return 0
    End If

    Dim expectedFields As Long = countApiStructFields(source)
    If expectedFields = 0 Then
        errorMessage = "sqlite3_api_routines structure was not found"
        Return 0
    End If
    Dim entries() As String
    Dim entryCount As Long = collectApiEntries(source, entries())
    If entryCount = 0 Then
        errorMessage = "sqlite3Apis initializer was not found"
        Return 0
    End If
    If entryCount <> expectedFields Then
        errorMessage = "API struct has " & Str(expectedFields) & _
            " fields but initializer has " & Str(entryCount) & " entries"
        Return 0
    End If

    Dim sourceDirectory As String = parentDirectory(modulePath)
    Dim bodyNames As String
    readFreeBasicApiBodyNames(sourceDirectory, bodyNames)
    Dim portedNames As String
    Dim csvError As String
    If readPortedApiNames( _
        csvText, bodyNames, portedNames, csvError) = 0 Then
        errorMessage = csvError
        Return 0
    End If
    Dim apiNames() As String
    ReDim apiNames(0 To entryCount - 1)
    Dim portedCount As Long = 0
    For entryIndex As Long = 0 To entryCount - 1
        apiNames(entryIndex) = apiNameFromEntry(entries(entryIndex))
        If apiNames(entryIndex) = "" Then _
            apiNames(entryIndex) = optionalApiNameForSlot(entryIndex)
        If apiNames(entryIndex) <> "" AndAlso _
           InStr(portedNames, "|" & apiNames(entryIndex) & "|") <> 0 Then
            portedCount += 1
        End If
    Next

    Dim fileOutput As C2fbGeneratedFileOutputModel
    If OpenC2fbGeneratedFileOutput(fileOutput, outputPath) = 0 Then
        errorMessage = "unable to open the output path"
        Return 0
    End If
    Dim fileComment As C2fbGeneratedFileCommentModel
    ResetC2fbGeneratedFileComment(fileComment)
    If AddC2fbGeneratedFileCommentLine(fileComment, "** 2006 June 7") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine(fileComment, "**") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "** The author disclaims copyright to this source code.  In place of") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "** a legal notice, here is a blessing:") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine(fileComment, "**") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "**    May you do good and not evil.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "**    May you find forgiveness for yourself and forgive others.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "**    May you share freely, never taking more than you give.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine(fileComment, "**") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    Project: SQLite FreeBASIC port") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    File: sqlite3_extension_api_table.bi") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    Purpose: Keep the C sqlite3_api_routines pointer layout for extensions.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    Source order: the preprocessed sqlite3Apis initializer.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    Unported API entries are null until their FreeBASIC bodies are present.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine(fileComment, "") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    Responsibilities:") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "        - Preserve every function-pointer slot and its C field order.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "        - Point to ported API bodies and leave missing bodies null.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine(fileComment, "") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    This file intentionally does NOT contain:") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "        - SQLite API implementations or extension-load behavior.") = 0 Then
        AbortC2fbGeneratedFileOutput(fileOutput)
        errorMessage = "API table file comment exceeds its limit"
        Return 0
    End If
    Dim filePreamble As C2fbGeneratedFilePreambleModel
    WriteC2fbGeneratedFilePreamble(fileOutput, fileComment, filePreamble)
    Dim fileGuard As C2fbGeneratedFileGuardModel
    If BeginC2fbGeneratedFileGuard( _
        fileOutput, fileGuard, "SQLITE3_FB_EXTENSION_API_TABLE_BI") = 0 Then
        AbortC2fbGeneratedFileOutput(fileOutput)
        errorMessage = "cannot open the API table include guard"
        Return 0
    End If
    For entryIndex As Long = 0 To entryCount - 1
        Dim apiName As String = apiNames(entryIndex)
        If apiName <> "" AndAlso _
           InStr(portedNames, "|" & apiName & "|") <> 0 AndAlso _
           ownerModuleTextDeclaresApi(ownerText, apiName) = 0 AndAlso _
           ownerHasApiDeclaration( _
               modulePath, sourceDirectory, apiName, outputPath) = 0 Then
            ' Function signatures do not affect the stored code address.
            Dim procedureBinding As C2fbProcedureBindingModel
            procedureBinding.freeBasicName = apiName
            procedureBinding.cName = apiName
            procedureBinding.returnType = "Any Ptr"
            procedureBinding.callingConvention = "CDecl"
            WriteC2fbProcedureBinding(fileOutput, procedureBinding)
        End If
    Next
    WriteC2fbGeneratedFileLine(fileOutput, "")
    WriteC2fbGeneratedFileLine( _
        fileOutput, "' C stores only function pointers in this struct; the pointer array preserves offsets.")
    WriteC2fbGeneratedFileLine( _
        fileOutput, "Private Dim Shared sqlite3Apis(0 To " & Str(entryCount - 1) & ") As Any Ptr")
    WriteC2fbGeneratedFileLine(fileOutput, "Private Dim Shared sqlite3ApiTableReady As u8")
    WriteC2fbGeneratedFileLine(fileOutput, "")
    WriteC2fbGeneratedFileLine( _
        fileOutput, "Private Function sqlite3InitializeApiTable() As SQLITE_C_INT")
    WriteC2fbGeneratedFileLine( _
        fileOutput, "    Dim pInitializationMutex As Any Ptr = sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_MASTER)")
    WriteC2fbGeneratedFileLine(fileOutput, "#if SQLITE_THREADSAFE <> 0")
    WriteC2fbGeneratedFileLine( _
        fileOutput, "    If pInitializationMutex = 0 Then Return SQLITE_MISUSE")
    WriteC2fbGeneratedFileLine(fileOutput, "#endif")
    WriteC2fbGeneratedFileLine( _
        fileOutput, "    If pInitializationMutex <> 0 Then sqlite3_mutex_enter(pInitializationMutex)")
    WriteC2fbGeneratedFileLine(fileOutput, "    If sqlite3ApiTableReady = 0 Then")
    For entryIndex As Long = 0 To entryCount - 1
        Dim apiName As String = apiNames(entryIndex)
        If apiName <> "" AndAlso InStr(portedNames, "|" & apiName & "|") <> 0 Then
            Dim apiGuard As String = optionalApiGuard(apiName)
            If apiGuard <> "" Then _
                WriteC2fbGeneratedFileLine(fileOutput, apiGuard)
            Dim requiresDeserialize As Long = _
                CInt(apiName = "sqlite3_deserialize" OrElse _
                     apiName = "sqlite3_serialize")
            If requiresDeserialize <> 0 Then
                ' loadext.c leaves these slots NULL under SQLITE_OMIT_DESERIALIZE.
                WriteC2fbGeneratedFileLine( _
                    fileOutput, "#ifndef SQLITE_OMIT_DESERIALIZE")
            End If
            WriteC2fbGeneratedFileLine( _
                fileOutput, "        sqlite3Apis(" & LTrim(Str(entryIndex)) & ") = CPtr(Any Ptr, ProcPtr(" & apiName & "))")
            If requiresDeserialize <> 0 Then _
                WriteC2fbGeneratedFileLine(fileOutput, "#endif")
            If apiGuard <> "" Then _
                WriteC2fbGeneratedFileLine(fileOutput, "#endif")
        End If
    Next
    WriteC2fbGeneratedFileLine(fileOutput, "        sqlite3ApiTableReady = 1")
    WriteC2fbGeneratedFileLine(fileOutput, "    End If")
    WriteC2fbGeneratedFileLine( _
        fileOutput, "    If pInitializationMutex <> 0 Then sqlite3_mutex_leave(pInitializationMutex)")
    WriteC2fbGeneratedFileLine(fileOutput, "    Return SQLITE_OK")
    WriteC2fbGeneratedFileLine(fileOutput, "End Function")
    If EndC2fbGeneratedFileGuard(fileOutput, fileGuard) = 0 Then
        AbortC2fbGeneratedFileOutput(fileOutput)
        errorMessage = "cannot close the API table include guard"
        Return 0
    End If
    WriteC2fbGeneratedFileLine( _
        fileOutput, "/' end of sqlite3_extension_api_table.bi '/")
    CloseC2fbGeneratedFileOutput(fileOutput)
    If C2fbGeneratedFileOutputHasFailed(fileOutput) <> 0 Then
        errorMessage = C2fbGeneratedFileOutputFailureMessage( _
            fileOutput, "cannot finish the API table file: " & outputPath)
        Return 0
    End If

    result.entryCount = entryCount
    result.portedCount = portedCount
    Return -1
End Function

Private Sub PrintC2fbApiRoutinesSummary( _
    ByRef result As C2fbApiRoutinesResultModel, _
    ByVal outputPath As String _
)
    Print "generated " & Str(result.entryCount) & " API slots (" & _
          Str(result.portedCount) & " backed by FreeBASIC bodies): " & _
          outputPath
End Sub

/' end of c2fb_api_routines.bi '/
