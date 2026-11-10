/'
    Project: C2FB body project catalog

    File: c2fb_body_call_signatures.bi

    Purpose:

        Index FreeBASIC call signatures for shared C body type inference.

    Responsibilities:

        - Parse existing FreeBASIC declarations into bounded signature records.
        - Resolve signature names, return types, and parameter types.
        - Provide known C runtime builtin signatures used by body expressions.
        - Merge duplicate declarations and reject conflicting signatures.

    This file intentionally does NOT contain:

        - C symbol registration or C body procedure lowering.
        - FreeBASIC file enumeration or C expression parsing.
'/

Private Function FbBodyCallSignatureIndex( _
    ByRef catalog As C2fbProjectCatalog, ByVal procedureName As String _
) As Long
    Dim indexedPosition As Long = C2fbStringIndexMapLookup( _
        catalog.bodyCallSignatureMap, procedureName)
    If indexedPosition < 0 Then Return -1
    If indexedPosition >= 0 AndAlso _
       indexedPosition < catalog.bodyCallSignatureCount Then
        With catalog.bodyCallSignatures(indexedPosition)
            If .name = procedureName OrElse .fbName = procedureName Then _
                Return indexedPosition
        End With
    End If

    ' A FreeBASIC alias can change when a fallback signature is replaced.
    ' Keep this scan as a correctness fallback for any stale index key.
    For i As Long = 0 To catalog.bodyCallSignatureCount - 1
        If catalog.bodyCallSignatures(i).name = procedureName OrElse _
           catalog.bodyCallSignatures(i).fbName = procedureName Then Return i
    Next
    Return -1
End Function

Private Function FbBodyCallSignatureAliasIndex( _
    ByRef catalog As C2fbProjectCatalog, ByVal cName As String _
) As Long
    Dim selectedIndex As Long = -1
    For i As Long = 0 To catalog.bodyCallSignatureCount - 1
        With catalog.bodyCallSignatures(i)
            If .canDeclare = 0 OrElse .parameterCount < 0 Then Continue For
            Dim aliasName As String = FbDeclarationAliasName(.declaration)
            If aliasName = "" Then _
                aliasName = FbProcedureAliasName(.declaration)
            If aliasName <> cName Then Continue For
            If selectedIndex < 0 Then
                selectedIndex = i
                Continue For
            End If
            With catalog.bodyCallSignatures(selectedIndex)
                Dim signaturesMatch As Long = CInt( _
                    .returnType = catalog.bodyCallSignatures(i).returnType AndAlso _
                    .parameterTypes = catalog.bodyCallSignatures(i).parameterTypes AndAlso _
                    .parameterCount = catalog.bodyCallSignatures(i).parameterCount AndAlso _
                    .isVariadic = catalog.bodyCallSignatures(i).isVariadic)
                If signaturesMatch <> 0 OrElse _
                   catalog.bodyCallSignatures(i).isFallback <> 0 Then Continue For
                If .isFallback <> 0 Then
                    selectedIndex = i
                Else
                    Return -1
                End If
            End With
        End With
    Next
    Return selectedIndex
End Function

Private Function CBodyBuiltinType(ByVal procedureName As String) As String
    Select Case procedureName
    Case "__builtin_bswap16": Return "UShort"
    Case "__builtin_bswap32": Return "ULong"
    Case "__builtin_bswap64": Return "ULongInt"
    End Select
    Return ""
End Function

Private Function CBodyBuiltinStdBitCountKind( _
    ByVal procedureName As String _
) As Long
    Select Case procedureName
    Case "__builtin_stdc_bit_width": Return 4
    Case "__builtin_stdc_leading_zeros": Return 1
    Case "__builtin_stdc_trailing_zeros": Return 2
    Case "__builtin_clz", "__builtin_clzl", "__builtin_clzll": Return 3
    Case "__builtin_ctz": Return 8
    Case "__builtin_ctzl": Return 9
    Case "__builtin_ctzll": Return 10
    Case "__builtin_popcount": Return 5
    Case "__builtin_popcountl": Return 6
    Case "__builtin_popcountll": Return 7
    End Select
    Return 0
End Function

Private Function CBodyBuiltinStdRotateKind( _
    ByVal procedureName As String _
) As Long
    Select Case procedureName
    Case "__builtin_stdc_rotate_left": Return 1
    Case "__builtin_stdc_rotate_right": Return 2
    End Select
    Return 0
End Function

Private Function CBodyBuiltinExpectKind(ByVal procedureName As String) As Long
    Select Case procedureName
    Case "__builtin_expect": Return 1
    Case "__builtin_expect_with_probability": Return 2
    End Select
    Return 0
End Function

Private Function CBodyBuiltinConstantP(ByVal procedureName As String) As Long
    Return CInt(procedureName = "__builtin_constant_p")
End Function

Private Function CBodyBuiltinCpuSupports( _
    ByVal procedureName As String _
) As Long
    Return CInt(procedureName = "__builtin_cpu_supports")
End Function

Private Function CBodyBuiltinInfinityType( _
    ByVal procedureName As String _
) As String
    Select Case procedureName
    Case "__builtin_huge_val", "__builtin_inf": Return "Double"
    Case "__builtin_huge_valf", "__builtin_inff": Return "Single"
    End Select
    Return ""
End Function

Private Function CBodyBuiltinNaNType( _
    ByVal procedureName As String _
) As String
    Select Case procedureName
    Case "__builtin_nan": Return "Double"
    Case "__builtin_nanf": Return "Single"
    Case "__builtin_nanl": Return "CLongDouble"
    End Select
    Return ""
End Function

Private Function CBodyFiniteTestBuiltin(ByVal procedureName As String) As Long
    Return CInt( _
        procedureName = "isfinite" OrElse _
        procedureName = "__builtin_isfinite")
End Function

Private Function CBodyNaNTestBuiltin(ByVal procedureName As String) As Long
    Return CInt( _
        procedureName = "isnan" OrElse _
        procedureName = "__builtin_isnan")
End Function

Private Function CBodyInfinitySignTestBuiltin( _
    ByVal procedureName As String _
) As Long
    Return CInt(procedureName = "__builtin_isinf_sign")
End Function

Private Function FbBodyCallSignatureParameterType( _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal procedureName As String, ByVal parameterIndex As Long _
) As String
    Dim signatureIndex As Long = _
        FbBodyCallSignatureIndex(catalog, procedureName)
    If signatureIndex < 0 OrElse _
       catalog.bodyCallSignatures(signatureIndex).parameterCount < 0 OrElse _
       parameterIndex < 0 OrElse _
       parameterIndex >= catalog.bodyCallSignatures(signatureIndex).parameterCount Then _
        Return ""
    Dim parameterTypes As String = _
        catalog.bodyCallSignatures(signatureIndex).parameterTypes
    Dim start As Long = 1
    For i As Long = 0 To parameterIndex - 1
        start = InStr(start, parameterTypes, "|") + 1
        If start <= 1 Then Return ""
    Next
    Dim finish As Long = InStr(start, parameterTypes, "|")
    If finish = 0 Then Return ""
    Return Mid(parameterTypes, start, finish - start)
End Function

Private Function CBodyCallParameterType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal procedureName As String, ByVal parameterIndex As Long _
) As String
    If CBodyBuiltinType(procedureName) <> "" Then
        If parameterIndex = 0 Then Return CBodyBuiltinType(procedureName)
        Return ""
    End If
    If CBodyBuiltinStdBitCountKind(procedureName) <> 0 Then Return ""
    If CBodyBuiltinConstantP(procedureName) <> 0 Then Return ""
    Dim lookupName As String = CBodyBuiltinCallTarget(procedureName)
    If lookupName = "" Then lookupName = procedureName
    Dim sourceType As String = CBodyParameterType( _
        translation, catalog, lookupName, parameterIndex)
    Dim sourceIndex As Long = CBodyProcedureIndex( _
        translation, lookupName)
    If sourceIndex >= 0 AndAlso _
       translation.symbolTable.symbols(sourceIndex).body.needsDefinition <> 0 Then _
        Return sourceType
    Dim freeBasicType As String = FbBodyCallSignatureParameterType( _
        catalog, lookupName, parameterIndex)
    If sourceType = "" OrElse freeBasicType = "" Then Return sourceType
    Dim sourceIsPointer As Long = CInt( _
        InStr(sourceType, " Ptr") <> 0 OrElse _
        IsCBodyCallbackTypeInContext(translation, sourceType) <> 0)
    Dim freeBasicIsPointer As Long = CInt( _
        InStr(freeBasicType, " Ptr") <> 0 OrElse _
        IsCBodyCallbackTypeInContext(translation, freeBasicType) <> 0)
    If sourceIsPointer <> 0 AndAlso freeBasicIsPointer <> 0 Then
        ' The C declaration describes argument semantics, but a call emitted
        ' against an existing FreeBASIC procedure must match that procedure's
        ' pointer parameter type. The expression retains its C pointee type;
        ' only the final ABI cast uses the indexed FreeBASIC signature.
        Return freeBasicType
    End If
    Return sourceType
End Function

Private Function ReadFbParameterType( _
    ByRef catalog As C2fbProjectCatalog, ByVal parameter As String _
) As String
    Dim lowered As String = LCase(parameter)
    Dim asPosition As Long = InStr(lowered, " as ")
    If asPosition = 0 Then Return ""
    Dim typeText As String = Trim(Mid(parameter, asPosition + 4))
    Dim defaultPosition As Long = InStr(typeText, "=")
    If defaultPosition <> 0 Then typeText = Trim(Left(typeText, defaultPosition - 1))
    If typeText = "" Then Return ""
    Return NormalizeFbBodyType(catalog, typeText)
End Function

Private Function NormalizeFbBodyParameterTypes( _
    ByRef catalog As C2fbProjectCatalog, ByVal parameterTypes As String _
) As String
    Dim normalizedTypes As String
    Dim startPosition As Long = 1
    While startPosition <= Len(parameterTypes)
        Dim separatorPosition As Long = InStr(startPosition, parameterTypes, "|")
        If separatorPosition = 0 Then separatorPosition = Len(parameterTypes) + 1
        Dim typeName As String = Trim(Mid( _
            parameterTypes, startPosition, separatorPosition - startPosition))
        If typeName <> "" Then _
            normalizedTypes &= NormalizeFbBodyType(catalog, typeName) & "|"
        startPosition = separatorPosition + 1
    Wend
    Return normalizedTypes
End Function

Private Sub RecordFbBodyCallSignature( _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceLine As String, _
    ByVal isFallback As Long = 0 _
)
    Dim procedureName As String = FbDeclarationName(sourceLine)
    If procedureName = "" Then procedureName = FbProcedureName(sourceLine)
    If procedureName = "" Then Exit Sub

    Dim lowered As String = LCase(sourceLine)
    Dim isSub As Long = CInt(InStr(lowered, "sub " & LCase(procedureName)) <> 0)
    Dim namePosition As Long = InStr(lowered, LCase(procedureName))
    If namePosition = 0 Then Exit Sub
    Dim opening As Long = InStr(namePosition + Len(procedureName), sourceLine, "(")
    If opening = 0 Then Exit Sub

    Dim nesting As Long = 1
    Dim closing As Long = opening + 1
    While closing <= Len(sourceLine) AndAlso nesting > 0
        Select Case Mid(sourceLine, closing, 1)
        Case "(": nesting += 1
        Case ")": nesting -= 1
        End Select
        closing += 1
    Wend
    If nesting <> 0 Then Exit Sub
    closing -= 1

    Dim returnType As String = "void"
    If isSub = 0 Then
        Dim resultText As String = Trim(Mid(sourceLine, closing + 1))
        Dim asPosition As Long = InStr(LCase(resultText), "as ")
        If asPosition = 0 Then Exit Sub
        returnType = Trim(Mid(resultText, asPosition + 3))
        While returnType <> ""
            Dim lastSpace As Long = 0
            For scanPosition As Long = Len(returnType) To 1 Step -1
                If IsSpaceByte(Asc(returnType, scanPosition)) <> 0 Then
                    lastSpace = scanPosition
                    Exit For
                End If
            Next
            Dim lastWord As String = LCase(Mid(returnType, lastSpace + 1))
            If lastWord = "export" OrElse lastWord = "static" Then
                If lastSpace = 0 Then Exit Sub
                returnType = Trim(Left(returnType, lastSpace - 1))
            Else
                Exit While
            End If
        Wend
        If returnType = "" Then Exit Sub
    End If
    returnType = NormalizeFbBodyType(catalog, returnType)

    Dim parameterTypes As String
    Dim parameterCount As Long = 0
    Dim isVariadic As Long = 0
    Dim parameterStart As Long = opening + 1
    nesting = 0
    For position As Long = parameterStart To closing
        Dim atEnd As Long = CInt(position = closing)
        If position < closing Then
            Select Case Mid(sourceLine, position, 1)
            Case "(": nesting += 1
            Case ")": If nesting > 0 Then nesting -= 1
            End Select
            If Mid(sourceLine, position, 1) = "," AndAlso nesting = 0 Then atEnd = -1
        End If
        If atEnd <> 0 Then
            Dim parameterText As String = Trim(Mid(sourceLine, parameterStart, position - parameterStart))
            If parameterText <> "" Then
                If parameterText = "..." Then
                    If isVariadic <> 0 Then Exit Sub
                    isVariadic = -1
                Else
                    If isVariadic <> 0 Then Exit Sub
                    ' Keep the fixed prefix for type conversion. Variadic
                    ' arguments have no declared FreeBASIC parameter type.
                    Dim parameterType As String = ReadFbParameterType(catalog, parameterText)
                    If parameterType = "" Then Exit Sub
                    parameterTypes &= parameterType & "|"
                    parameterCount += 1
                End If
            End If
            parameterStart = position + 1
        End If
    Next

    Dim procedureAlias As String = FbDeclarationAliasName(sourceLine)
    If procedureAlias = "" Then procedureAlias = FbProcedureAliasName(sourceLine)
    Dim signatureName As String = procedureAlias
    If signatureName = "" Then signatureName = procedureName
    Dim loweredDeclaration As String = LCase(LTrim(sourceLine))
    Dim isPrivate As Long = CInt(Left(loweredDeclaration, 8) = "private " OrElse _
                                 Left(loweredDeclaration, 7) = "static ")
    Dim canDeclare As Long = CInt(isPrivate = 0)
    Dim index As Long = FbBodyCallSignatureIndex(catalog, signatureName)
    If index < 0 Then index = FbBodyCallSignatureIndex(catalog, procedureName)
    If index >= 0 AndAlso catalog.bodyCallSignatures(index).parameterCount >= 0 Then
        ' Type aliases can be declared in a different .bi that is scanned later.
        ' Re-resolve older signatures before comparing them with this declaration.
        With catalog.bodyCallSignatures(index)
            .returnType = NormalizeFbBodyType(catalog, .returnType)
            .parameterTypes = NormalizeFbBodyParameterTypes( _
                catalog, .parameterTypes)
        End With
    End If
    If index < 0 Then
        If catalog.bodyCallSignatureCount >= MAX_FUNCTIONS Then _
            ReportError("FreeBASIC source exceeds the configured call-signature limit")
        If catalog.bodyCallSignatureCount > UBound(catalog.bodyCallSignatures) Then _
            ReDim Preserve catalog.bodyCallSignatures(0 To UBound(catalog.bodyCallSignatures) * 2 + 1)
        index = catalog.bodyCallSignatureCount
        catalog.bodyCallSignatureCount += 1
        catalog.bodyCallSignatures(index).name = signatureName
        catalog.bodyCallSignatures(index).fbName = procedureName
        catalog.bodyCallSignatures(index).returnType = returnType
        catalog.bodyCallSignatures(index).parameterTypes = parameterTypes
        catalog.bodyCallSignatures(index).parameterCount = parameterCount
        catalog.bodyCallSignatures(index).isVariadic = isVariadic
        catalog.bodyCallSignatures(index).declaration = sourceLine
        catalog.bodyCallSignatures(index).canDeclare = canDeclare
        catalog.bodyCallSignatures(index).isPrivate = isPrivate
        catalog.bodyCallSignatures(index).isFallback = isFallback
    Else
        If isFallback = 0 Then
            ' A conflicting public declaration is still public. Keep visibility
            ' separate from whether one unambiguous signature can be emitted.
            If catalog.bodyCallSignatures(index).isFallback <> 0 Then
                catalog.bodyCallSignatures(index).isPrivate = isPrivate
            Else
                catalog.bodyCallSignatures(index).isPrivate = CInt( _
                    catalog.bodyCallSignatures(index).isPrivate <> 0 AndAlso _
                    isPrivate <> 0) * -1
            End If
        End If
        Dim signatureMatches As Long = CInt( _
            catalog.bodyCallSignatures(index).returnType = returnType AndAlso _
            catalog.bodyCallSignatures(index).parameterTypes = parameterTypes AndAlso _
            catalog.bodyCallSignatures(index).parameterCount = parameterCount AndAlso _
            catalog.bodyCallSignatures(index).isVariadic = isVariadic)
        If signatureMatches <> 0 Then
            If canDeclare <> 0 AndAlso _
               catalog.bodyCallSignatures(index).isFallback <> 0 AndAlso _
               isFallback = 0 Then
                ' Replace a generic runtime fallback with the project's
                ' explicit alias so generated calls use its FreeBASIC name.
                catalog.bodyCallSignatures(index).fbName = procedureName
                catalog.bodyCallSignatures(index).declaration = sourceLine
                catalog.bodyCallSignatures(index).canDeclare = canDeclare
                catalog.bodyCallSignatures(index).isPrivate = isPrivate
                catalog.bodyCallSignatures(index).isFallback = 0
            ElseIf canDeclare <> 0 AndAlso _
                   catalog.bodyCallSignatures(index).fbName = procedureName Then
                catalog.bodyCallSignatures(index).declaration = sourceLine
                catalog.bodyCallSignatures(index).canDeclare = -1
                If isFallback = 0 Then _
                    catalog.bodyCallSignatures(index).isFallback = 0
            ElseIf isFallback = 0 AndAlso _
                   catalog.bodyCallSignatures(index).isFallback = 0 Then
                catalog.bodyCallSignatures(index).canDeclare = CInt( _
                    catalog.bodyCallSignatures(index).canDeclare <> 0 OrElse _
                    canDeclare <> 0) * -1
            End If
        ElseIf catalog.bodyCallSignatures(index).isFallback <> 0 AndAlso _
               isFallback = 0 AndAlso canDeclare <> 0 Then
            ' A typed project declaration is more useful than an erased
            ' Any-Ptr signature from the generated internal API index.
            With catalog.bodyCallSignatures(index)
                .fbName = procedureName
                .returnType = returnType
                .parameterTypes = parameterTypes
                .parameterCount = parameterCount
                .isVariadic = isVariadic
                .declaration = sourceLine
                .canDeclare = canDeclare
                .isPrivate = isPrivate
                .isFallback = 0
            End With
        ElseIf catalog.bodyCallSignatures(index).isFallback = 0 AndAlso _
               isFallback <> 0 Then
            ' Keep the project-owned signature when the generic API index
            ' repeats the same linker name with erased pointer types.
        Else
            ' Conflicting project declarations without a declared fallback
            ' policy are unsafe to use for body-call lowering.
            catalog.bodyCallSignatures(index).returnType = ""
            catalog.bodyCallSignatures(index).parameterTypes = ""
            catalog.bodyCallSignatures(index).parameterCount = -1
            catalog.bodyCallSignatures(index).isVariadic = 0
            catalog.bodyCallSignatures(index).canDeclare = 0
            catalog.bodyCallSignatures(index).isFallback = 0
        End If
    End If

    If AddC2fbStringIndexMapEntry( _
        catalog.bodyCallSignatureMap, catalog.bodyCallSignatures(index).name, _
        index) = 0 OrElse _
       AddC2fbStringIndexMapEntry( _
        catalog.bodyCallSignatureMap, catalog.bodyCallSignatures(index).fbName, _
        index) = 0 Then _
        ReportError("FreeBASIC call-signature name index exceeds the configured limit")
End Sub

/' end of c2fb_body_call_signatures.bi '/
