/'
    Project: C2FB parameter lowering
    -------------------------------

    File: c2fb_parameters.bi

    Purpose:

        Convert C parameter declarations into the shared FreeBASIC parameter
        representation used by header, callback, symbol, and body passes.

    Responsibilities:

        - Adjust C array parameters to pointer types.
        - Resolve callback and generic-header parameter types consistently.
        - Preserve body array typedef extents for sizeof and parameter lowering.
        - Return typed conversion state, names, and FreeBASIC type declarations.
        - Keep omitted, variadic, and unsupported outcomes distinct.

    This file intentionally does NOT contain:

        - Function eligibility, calling-convention selection, or prototype emission.
        - C declaration collection or generated output formatting.
'/

Private Function ParameterAlias( _
    parameterNames() As String, _
    parameterAliases() As String, _
    ByVal parameterCount As Long, _
    ByVal sourceName As String _
) As String
    For i As Long = parameterCount - 1 To 0 Step -1
        If parameterNames(i) = sourceName Then Return parameterAliases(i)
    Next
    Return ""
End Function

Private Function CBodyArrayTypeSizeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceText As String, ByRef position As Long, _
    ByRef sizeExpression As String _
) As Long
    sizeExpression = ""
    Dim groupStart As Long = position
    While groupStart <= Len(sourceText) AndAlso _
          IsSpaceByte(Asc(sourceText, groupStart)) <> 0
        groupStart += 1
    Wend
    If groupStart > Len(sourceText) OrElse _
       Asc(sourceText, groupStart) <> Asc("(") Then Return 0

    Dim groupEnd As Long = groupStart
    If ScanSimpleExpressionGroup( _
        sourceText, groupEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim typeName As String = Trim(Mid( _
        sourceText, groupStart + 1, groupEnd - groupStart - 2))
    If typeName = "" Then Return 0

    If IsIdentifierToken(typeName) <> 0 Then
        For aliasIndex As Long = 0 To translation.body.aliasCount - 1
            With translation.body.aliases(aliasIndex)
                If .name = typeName AndAlso .isArray <> 0 AndAlso _
                   .ambiguous = 0 AndAlso .arrayCount > 0 AndAlso _
                   .arrayElementType <> "" Then
                    sizeExpression = "Cast(c2fb_size_t, (" & _
                        Trim(Str(.arrayCount)) & " * SizeOf(" & _
                        .arrayElementType & ")))"
                    position = groupEnd
                    Return -1
                End If
            End With
        Next
    End If

    Dim arrayStart As Long = 0
    Dim typeParenthesisDepth As Long = 0
    For typePosition As Long = 1 To Len(typeName)
        Select Case Asc(typeName, typePosition)
        Case Asc("("): typeParenthesisDepth += 1
        Case Asc(")"):
            If typeParenthesisDepth = 0 Then Return 0
            typeParenthesisDepth -= 1
        Case Asc("[")
            If typeParenthesisDepth = 0 Then
                arrayStart = typePosition
                Exit For
            End If
        End Select
    Next
    If typeParenthesisDepth <> 0 OrElse arrayStart <= 1 Then Return 0

    Dim baseTypeText As String = Trim(Left(typeName, arrayStart - 1))
    If baseTypeText = "" Then Return 0
    Dim baseTypeTokens() As String
    Dim baseTypeTokenCount As Long = 0
    TokenizeCDeclaration(baseTypeText, baseTypeTokens(), baseTypeTokenCount)
    If baseTypeTokenCount = 0 OrElse _
       baseTypeTokenCount >= MAX_TYPE_WORDS Then Return 0
    If C2fbTypeRecognitionStatusInContext( _
        translation, catalog, baseTypeTokens(), 0, _
        baseTypeTokenCount - 1) <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0

    Dim elementType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        translation, catalog, baseTypeTokens(), 0, _
        baseTypeTokenCount - 1, elementType, _
        C2FB_POINTER_MAPPING_PRESERVE, C2FB_TYPE_MAPPING_BODY, _
        C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
    If elementType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0

    Dim freeBasicElementType As String = elementType.freeBasicType
    If Left(freeBasicElementType, 6) = "Const " Then _
        freeBasicElementType = Mid(freeBasicElementType, 7)
    If freeBasicElementType = "" Then Return 0
    If elementType.pointerCount = 0 Then
        Dim sourceRecord As String = CBodyRecordName( _
            translation, catalog, freeBasicElementType)
        If sourceRecord <> "" AndAlso CBodyRecordSizeIsKnown( _
            translation, catalog, sourceRecord) = 0 Then Return 0
    End If

    Dim elementCount As ULongInt = 1
    Dim tokenPosition As Long = arrayStart
    Dim arrayRank As Long = 0
    While tokenPosition <= Len(typeName)
        While tokenPosition <= Len(typeName) AndAlso _
              IsSpaceByte(Asc(typeName, tokenPosition)) <> 0
            tokenPosition += 1
        Wend
        If tokenPosition > Len(typeName) Then Exit While
        If Asc(typeName, tokenPosition) <> Asc("[") Then Return 0
        arrayRank += 1
        If arrayRank > MAX_GENERIC_ARRAY_RANK Then Return 0
        Dim boundStart As Long = tokenPosition + 1
        tokenPosition = boundStart
        Dim parenthesisDepth As Long = 0
        Dim foundBoundEnd As Long = 0
        While tokenPosition <= Len(typeName)
            Select Case Asc(typeName, tokenPosition)
            Case Asc("("): parenthesisDepth += 1
            Case Asc(")"):
                If parenthesisDepth = 0 Then Return 0
                parenthesisDepth -= 1
            Case Asc("[")
                If parenthesisDepth = 0 Then Return 0
            Case Asc("]")
                If parenthesisDepth = 0 Then
                    foundBoundEnd = -1
                    Exit While
                End If
            End Select
            tokenPosition += 1
        Wend
        If foundBoundEnd = 0 OrElse tokenPosition = boundStart Then Return 0

        Dim boundExpression As String = Trim(Mid( _
            typeName, boundStart, tokenPosition - boundStart))
        Dim boundCount As Long
        If EvaluateSimpleArrayBound( _
            boundExpression, boundCount, MAX_GENERIC_ARRAY_COUNT) = 0 OrElse _
           boundCount < 1 OrElse _
           elementCount > CULngInt(MAX_GENERIC_ARRAY_COUNT) / _
                          CULngInt(boundCount) Then Return 0
        elementCount *= CULngInt(boundCount)
        tokenPosition += 1
    Wend

    sizeExpression = "Cast(c2fb_size_t, (" & _
        Trim(Str(CLngInt(elementCount))) & "ULL * SizeOf(" & _
        freeBasicElementType & ")))"
    position = groupEnd
    Return -1
End Function

Private Function CBodyArrayTypedefParameterTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    tokens() As String, ByVal firstToken As Long, _
    ByVal lastToken As Long _
) As String
    Dim typeName As String = ""
    Dim isConst As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        Select Case tokens(tokenIndex)
        Case "const"
            isConst = -1
        Case "volatile", "restrict", "__restrict", "__restrict__", "register"
            Continue For
        Case "*", "[", "]", "(", ")"
            ' Pointer-to-array and grouped forms keep their ordinary declarator path.
            Return ""
        Case Else
            If IsIdentifierToken(tokens(tokenIndex)) = 0 Then Return ""
            If typeName <> "" Then Return ""
            typeName = tokens(tokenIndex)
        End Select
    Next
    If typeName = "" Then Return ""

    For aliasIndex As Long = 0 To translation.body.aliasCount - 1
        With translation.body.aliases(aliasIndex)
            If .name <> typeName OrElse .isArray = 0 OrElse _
               .ambiguous <> 0 OrElse .arrayElementType = "" Then Continue For
            Dim elementType As String = .arrayElementType
            If isConst <> 0 Then
                If InStr(elementType, " Ptr") <> 0 Then Return ""
                If Left(elementType, 6) <> "Const " Then elementType = "Const " & elementType
            End If
            Return elementType & " Ptr"
        End With
    Next

    ' Header typedefs may be inside include guards, so their body aliases can
    ' be absent even though the generic header pass retained their array type.
    Dim headerAliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, typeName, 0)
    If headerAliasIndex >= 0 Then
        With translation.genericC.header.headerTypeAliases(headerAliasIndex)
            If .isArray <> 0 AndAlso .arrayElementType <> "" Then
                Dim elementType As String = .arrayElementType
                If isConst <> 0 Then
                    If InStr(elementType, " Ptr") <> 0 Then Return ""
                    If Left(elementType, 6) <> "Const " Then _
                        elementType = "Const " & elementType
                End If
                Return elementType & " Ptr"
            End If
        End With
    End If
    Return ""
End Function

Private Function CBodyPointerToArrayTypedefParameterInContext( _
    ByRef translation As C2fbTranslationContext, _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef arrayElementType As String, ByRef arrayElementCount As Long, _
    ByRef arrayElementIsConst As Long _
) As Long
    arrayElementType = ""
    arrayElementCount = 0
    arrayElementIsConst = 0
    Dim typeName As String = ""
    Dim pointerDepth As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        Select Case tokens(tokenIndex)
        Case "const"
            If pointerDepth = 0 Then arrayElementIsConst = -1
        Case "volatile", "restrict", "__restrict", "__restrict__", "register"
            Continue For
        Case "*"
            pointerDepth += 1
        Case "[", "]", "(", ")"
            Return 0
        Case Else
            If IsIdentifierToken(tokens(tokenIndex)) = 0 OrElse typeName <> "" Then _
                Return 0
            typeName = tokens(tokenIndex)
        End Select
    Next
    If typeName = "" OrElse pointerDepth <> 1 Then Return 0
    For aliasIndex As Long = 0 To translation.body.aliasCount - 1
        With translation.body.aliases(aliasIndex)
            If .name <> typeName OrElse .isArray = 0 OrElse _
               .ambiguous <> 0 OrElse .arrayCount <= 0 OrElse _
               .arrayElementType = "" Then Continue For
            arrayElementType = .arrayElementType
            arrayElementCount = .arrayCount
            If .isConst <> 0 Then arrayElementIsConst = -1
            If arrayElementIsConst <> 0 AndAlso _
               Left(arrayElementType, 6) <> "Const " Then _
                arrayElementType = "Const " & arrayElementType
            Return -1
        End With
    Next
    Dim headerAliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, typeName, 0)
    If headerAliasIndex >= 0 Then
        With translation.genericC.header.headerTypeAliases(headerAliasIndex)
            If .isArray <> 0 AndAlso .arrayCount > 0 AndAlso _
               .arrayElementType <> "" Then
                arrayElementType = .arrayElementType
                arrayElementCount = .arrayCount
                If arrayElementIsConst <> 0 AndAlso _
                   Left(arrayElementType, 6) <> "Const " Then _
                    arrayElementType = "Const " & arrayElementType
                Return -1
            End If
        End With
    End If
    Return 0
End Function

Private Sub SetC2fbParameterConversionResult( _
    ByRef result As C2fbParameterConversionResultModel, _
    ByVal argumentNumber As Long, _
    ByVal sourceName As String, _
    ByVal freeBasicType As String, ByVal isByRef As Long = 0 _
)
    result.argumentName = "arg" & Trim(Str(argumentNumber))
    result.sourceName = sourceName
    If result.sourceName = "" Then result.sourceName = result.argumentName
    result.freeBasicType = freeBasicType
    result.isByRef = isByRef
    result.freeBasicDeclaration = ""
    result.defaultValue = ""
    If freeBasicType = "" Then
        result.status = C2FB_PARAMETER_CONVERSION_UNSUPPORTED
        Exit Sub
    End If
    result.status = C2FB_PARAMETER_CONVERSION_CONVERTED
    result.freeBasicDeclaration = result.argumentName & " As " & freeBasicType
End Sub

Private Function C2fbCallbackParameterTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef callbackResult As C2fbCallbackTypeResultModel, _
    ByVal typeMappingKind As C2fbTypeMappingKind _
) As String
    Dim callbackType As String = callbackResult.freeBasicType
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then _
        Return CBodyCallbackDeclarationInContext(translation, callbackType)
    ' The procedure alias already represents the innermost C function pointer.
    ' Keep only the pointer layers wrapped around that function pointer.
    If callbackResult.pointerDepth < 1 OrElse _
       callbackResult.pointerDepth > MAX_FREEBASIC_POINTER_LEVELS Then Return ""
    For pointerIndex As Long = 2 To callbackResult.pointerDepth
        callbackType &= " Ptr"
    Next
    Return callbackType
End Function

Private Sub ConvertParameterInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    tokens() As String, _
    ByVal firstToken As Long, _
    ByVal lastToken As Long, _
    ByVal argumentNumber As Long, _
    ByRef result As C2fbParameterConversionResultModel, _
    ByVal pointerMappingPolicy As C2fbPointerMappingPolicy = C2FB_POINTER_MAPPING_PRESERVE, _
    ByVal typeMappingKind As C2fbTypeMappingKind = C2FB_TYPE_MAPPING_BODY, _
    ByVal ownerName As String = "" _
)
    result.status = C2FB_PARAMETER_CONVERSION_UNSUPPORTED
    result.sourceName = "arg" & Trim(Str(argumentNumber))
    result.argumentName = result.sourceName
    result.freeBasicType = ""
    result.freeBasicDeclaration = ""
    result.defaultValue = ""
    result.isByRef = 0
    If firstToken > lastToken Then
        result.status = C2FB_PARAMETER_CONVERSION_OMITTED
        Exit Sub
    End If
    If firstToken = lastToken AndAlso tokens(firstToken) = "void" Then
        result.status = C2FB_PARAMETER_CONVERSION_OMITTED
        Exit Sub
    End If

    Dim isReferenceParameter As Long = 0
    Dim referenceParenDepth As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        If tokens(tokenIndex) = "(" Then
            referenceParenDepth += 1
        ElseIf tokens(tokenIndex) = ")" AndAlso referenceParenDepth > 0 Then
            referenceParenDepth -= 1
        ElseIf tokens(tokenIndex) = "&" AndAlso referenceParenDepth = 0 Then
            If typeMappingKind <> C2FB_TYPE_MAPPING_GENERIC_HEADER OrElse _
               isReferenceParameter <> 0 Then Return
            isReferenceParameter = -1
        End If
    Next

    Dim parameterName As String = result.sourceName
    For i As Long = firstToken To lastToken
        If tokens(i) = "..." Then
            result.status = C2FB_PARAMETER_CONVERSION_VARIADIC
            Exit Sub
        End If
        If tokens(i) = "(" AndAlso i + 2 <= lastToken AndAlso tokens(i + 1) = "*" Then
            If pointerMappingPolicy = C2FB_POINTER_MAPPING_PRESERVE OrElse typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
                Dim callbackResult As C2fbCallbackTypeResultModel
                Dim allowCallbackPointerLayers As Long = 0
                If typeMappingKind = C2FB_TYPE_MAPPING_BODY Then _
                    allowCallbackPointerLayers = -1
                ResolveCBodyCallbackTypeInContext( _
                    translation, catalog, tokens(), firstToken, lastToken, _
                    callbackResult, 0, typeMappingKind, _
                    allowCallbackPointerLayers)
                If callbackResult.status = C2FB_CALLBACK_TYPE_UNSUPPORTED Then Exit Sub
                If callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED Then
                    parameterName = callbackResult.callbackName
                    If parameterName = "" Then parameterName = "arg" & Trim(Str(argumentNumber))
                    Dim callbackType As String = _
                        C2fbCallbackParameterTypeInContext( _
                            translation, callbackResult, typeMappingKind)
                    If callbackType = "" Then Exit Sub
                    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
                        Dim callbackStringMode As Long = _
                            GenericStringOverrideModeForFieldInPolicy( _
                                translation.genericC.policy, ownerName, "", _
                                parameterName, argumentNumber)
                        callbackType = ApplyGenericStringOverrideModeInHeader( _
                            translation.genericC.header, callbackStringMode, callbackType)
                    End If
                    SetC2fbParameterConversionResult( _
                        result, argumentNumber, parameterName, callbackType)
                    Exit Sub
                End If
            End If
            Dim closePointer As Long = i + 2
            If IsIdentifierToken(tokens(closePointer)) <> 0 AndAlso _
               IsTypeOrQualifierTokenInContext( _
                   translation, tokens(closePointer)) = 0 Then
                parameterName = tokens(closePointer)
                closePointer += 1
            End If
            If closePointer + 1 <= lastToken AndAlso tokens(closePointer) = ")" AndAlso _
               tokens(closePointer + 1) = "(" Then
                SetC2fbParameterConversionResult( _
                    result, argumentNumber, parameterName, "Any Ptr")
                Exit Sub
            End If
        End If
    Next

    If pointerMappingPolicy = C2FB_POINTER_MAPPING_PRESERVE OrElse _
       typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        Dim callbackResult As C2fbCallbackTypeResultModel
        Dim allowCallbackPointerLayers As Long = 0
        If typeMappingKind = C2FB_TYPE_MAPPING_BODY Then _
            allowCallbackPointerLayers = -1
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, tokens(), firstToken, lastToken, _
            callbackResult, 0, typeMappingKind, _
            allowCallbackPointerLayers, -1)
        If callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED Then
            parameterName = callbackResult.callbackName
            If parameterName = "" Then parameterName = "arg" & Trim(Str(argumentNumber))
            Dim callbackType As String = _
                C2fbCallbackParameterTypeInContext( _
                    translation, callbackResult, typeMappingKind)
            If callbackType = "" Then Exit Sub
            If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
                Dim callbackStringMode As Long = _
                    GenericStringOverrideModeForFieldInPolicy( _
                        translation.genericC.policy, ownerName, "", _
                        parameterName, argumentNumber)
                callbackType = ApplyGenericStringOverrideModeInHeader( _
                    translation.genericC.header, callbackStringMode, callbackType)
            End If
            SetC2fbParameterConversionResult( _
                result, argumentNumber, parameterName, callbackType)
            Exit Sub
        ElseIf callbackResult.status = C2FB_CALLBACK_TYPE_UNSUPPORTED AndAlso _
               callbackResult.callbackName <> "" Then
            Exit Sub
        End If
    End If

    Dim nameIndex As Long = -1
    Dim arrayIndex As Long = -1
    For i As Long = firstToken To lastToken
        If tokens(i) = "[" AndAlso arrayIndex = -1 Then arrayIndex = i
    Next
    If arrayIndex > firstToken Then
        Dim candidate As Long = arrayIndex - 1
        If IsIdentifierToken(tokens(candidate)) AndAlso _
           IsTypeOrQualifierTokenInContext(translation, tokens(candidate)) = 0 Then
            For i As Long = firstToken To candidate - 1
                If IsQualifierToken(tokens(i)) = 0 AndAlso tokens(i) <> "*" Then
                    nameIndex = candidate
                    Exit For
                End If
                If tokens(i) = "*" Then nameIndex = candidate
            Next
        End If
    ElseIf IsIdentifierToken(tokens(lastToken)) AndAlso _
           IsTypeOrQualifierTokenInContext(translation, tokens(lastToken)) = 0 Then
        For i As Long = firstToken To lastToken - 1
            If IsQualifierToken(tokens(i)) = 0 AndAlso tokens(i) <> "*" Then
                nameIndex = lastToken
                Exit For
            End If
            If tokens(i) = "*" Then nameIndex = lastToken
        Next
    End If

    Dim typeEnd As Long = lastToken
    If nameIndex >= firstToken Then
        typeEnd = nameIndex - 1
        parameterName = tokens(nameIndex)
    End If
    If typeEnd < firstToken Then
        nameIndex = -1
        typeEnd = lastToken
    End If

    Dim referenceBaseConst As Long = 0
    Dim resolvedTokens() As String
    Dim resolvedFirstToken As Long = firstToken
    Dim resolvedLastToken As Long = typeEnd
    If isReferenceParameter <> 0 Then
        Dim sawPointerBeforeConst As Long = 0
        ReDim resolvedTokens(0 To typeEnd - firstToken)
        Dim resolvedTokenCount As Long = 0
        For tokenIndex As Long = firstToken To typeEnd
            If tokens(tokenIndex) = "*" Then sawPointerBeforeConst = -1
            If tokens(tokenIndex) = "const" AndAlso sawPointerBeforeConst = 0 Then _
                referenceBaseConst = -1
            If tokens(tokenIndex) = "&" Then Continue For
            AddToken(resolvedTokens(), resolvedTokenCount, tokens(tokenIndex))
        Next
        If resolvedTokenCount = 0 Then Return
        resolvedFirstToken = 0
        resolvedLastToken = resolvedTokenCount - 1
    End If

    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        Dim arrayAliasIndex As Long = -1
        Dim arrayPointerDepth As Long = 0
        Dim arrayElementConst As Long = 0
        For typeToken As Long = firstToken To typeEnd
            If tokens(typeToken) = "*" Then
                arrayPointerDepth += 1
            ElseIf tokens(typeToken) = "const" AndAlso arrayPointerDepth = 0 Then
                arrayElementConst = -1
            Else
                Dim candidateAlias As Long = _
                    GenericHeaderTypeAliasIndexInHeader( _
                        translation.genericC.header, tokens(typeToken), 0)
                If candidateAlias >= 0 AndAlso _
                   translation.genericC.header.headerTypeAliases(candidateAlias).isArray <> 0 Then
                    arrayAliasIndex = candidateAlias
                End If
            End If
        Next
        If arrayAliasIndex >= 0 Then
            Dim parameterType As String
            If arrayPointerDepth = 0 Then
                Dim parameterStringMode As Long = _
                    GenericStringOverrideModeForFieldInPolicy( _
                        translation.genericC.policy, ownerName, "", _
                        parameterName, argumentNumber)
                Dim arrayTypeStringMode As Long = parameterStringMode
                If arrayTypeStringMode = 0 Then _
                    arrayTypeStringMode = GenericStringOverrideModeInPolicy( _
                        translation.genericC.policy, _
                        translation.genericC.header.headerTypeAliases(arrayAliasIndex).sourceName)
                If arrayTypeStringMode = 0 Then _
                    arrayTypeStringMode = GenericHeaderFbfrogStringDefaultMode( _
                        translation, _
                        translation.genericC.header.headerTypeAliases(arrayAliasIndex).sourceName, _
                        translation.genericC.header.headerTypeAliases(arrayAliasIndex).arrayElementType)
                If arrayTypeStringMode > 0 Then
                    parameterType = GenericStringPointerTypeInHeader( _
                        translation.genericC.header, _
                        translation.genericC.header.headerTypeAliases(arrayAliasIndex).arrayElementType)
                End If
                If parameterType = "" Then
                    parameterType = _
                        translation.genericC.header.headerTypeAliases(arrayAliasIndex).arrayElementType
                    If arrayElementConst <> 0 AndAlso InStr(parameterType, " Ptr") = 0 AndAlso _
                       Left(parameterType, 6) <> "Const " Then parameterType = "Const " & parameterType
                    parameterType &= " Ptr"
                End If
            Else
                parameterType = "Any Ptr"
                For pointerIndex As Long = 2 To arrayPointerDepth
                    parameterType &= " Ptr"
                Next
            End If
            parameterType = ApplyGenericStringOverrideModeInHeader( _
                translation.genericC.header, _
                GenericStringOverrideModeForFieldInPolicy( _
                    translation.genericC.policy, ownerName, "", _
                    parameterName, argumentNumber), parameterType)
            SetC2fbParameterConversionResult( _
                result, argumentNumber, parameterName, parameterType)
            Exit Sub
        End If
    End If

    If typeMappingKind = C2FB_TYPE_MAPPING_BODY Then
        ' An unnamed prototype parameter can consist solely of an array typedef.
        ' C still decays that parameter to a pointer when nameIndex is absent.
        Dim arrayTypedefType As String = CBodyArrayTypedefParameterTypeInContext( _
            translation, tokens(), firstToken, typeEnd)
        If arrayTypedefType <> "" Then
            SetC2fbParameterConversionResult( _
                result, argumentNumber, parameterName, arrayTypedefType)
            Exit Sub
        End If
    End If

    If typeMappingKind = C2FB_TYPE_MAPPING_BODY AndAlso nameIndex >= firstToken Then
        If arrayIndex > firstToken Then
            Dim directArrayRank As Long = 0
            Dim arrayPosition As Long = nameIndex + 1
            While arrayPosition <= lastToken AndAlso tokens(arrayPosition) = "["
                Dim arrayClose As Long = -1
                Dim nestedDepth As Long = 0
                For scanIndex As Long = arrayPosition + 1 To lastToken
                    If tokens(scanIndex) = "[" Then
                        nestedDepth += 1
                    ElseIf tokens(scanIndex) = "]" Then
                        If nestedDepth = 0 Then
                            arrayClose = scanIndex
                            Exit For
                        End If
                        nestedDepth -= 1
                    End If
                Next
                If arrayClose < 0 Then Return
                directArrayRank += 1
                arrayPosition = arrayClose + 1
            Wend
            If directArrayRank >= 2 Then
                ' A multidimensional C parameter decays to a pointer to its
                ' first row. Preserve the scalar element ABI in that pointer
                ' so body indexing can apply the inner row stride.
                Dim resolvedArrayElementType As C2fbResolvedTypeModel
                ResolveC2fbTypeModel( _
                    translation, catalog, tokens(), firstToken, typeEnd, _
                    resolvedArrayElementType, C2FB_POINTER_MAPPING_PRESERVE, _
                    C2FB_TYPE_MAPPING_BODY)
                If resolvedArrayElementType.status <> _
                   C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
                   resolvedArrayElementType.freeBasicType = "" OrElse _
                   resolvedArrayElementType.freeBasicType = "void" Then Return
                Dim pointerArrayType As String = _
                    resolvedArrayElementType.freeBasicType
                If resolvedArrayElementType.isConst <> 0 AndAlso _
                   Left(pointerArrayType, 6) <> "Const " Then _
                    pointerArrayType = "Const " & pointerArrayType
                pointerArrayType &= " Ptr"
                SetC2fbParameterConversionResult( _
                    result, argumentNumber, parameterName, pointerArrayType)
                Exit Sub
            End If
        End If
    End If

    Dim resolvedParameterType As C2fbResolvedTypeModel
    If arrayIndex > firstToken AndAlso nameIndex >= firstToken Then
        ' In a C parameter list, an array declarator is adjusted to a pointer
        ' before the procedure ABI is formed. FreeBASIC needs that pointer
        ' type explicitly because it has no C-style array parameters.
        Dim adjustedTypeTokens() As String
        ReDim adjustedTypeTokens(0 To 31)
        Dim adjustedTokenCount As Long = 0
        For i As Long = resolvedFirstToken To resolvedLastToken
            If isReferenceParameter <> 0 Then
                AddToken(adjustedTypeTokens(), adjustedTokenCount, resolvedTokens(i))
            Else
                AddToken(adjustedTypeTokens(), adjustedTokenCount, tokens(i))
            End If
        Next
        AddToken(adjustedTypeTokens(), adjustedTokenCount, "*")
        ResolveC2fbTypeModel(translation, catalog, _
            adjustedTypeTokens(), 0, adjustedTokenCount - 1, resolvedParameterType, _
            pointerMappingPolicy, typeMappingKind)
    Else
        If isReferenceParameter <> 0 Then
            ResolveC2fbTypeModel(translation, catalog, _
                resolvedTokens(), resolvedFirstToken, resolvedLastToken, _
                resolvedParameterType, pointerMappingPolicy, typeMappingKind)
        Else
            ResolveC2fbTypeModel(translation, catalog, _
                tokens(), firstToken, typeEnd, resolvedParameterType, _
                pointerMappingPolicy, typeMappingKind)
        End If
    End If
    If resolvedParameterType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Exit Sub
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER AndAlso _
       resolvedParameterType.pointerCount = 0 AndAlso _
       GenericHeaderTypeIsOpaqueEmptyRecordInHeader( _
        translation.genericC.header, resolvedParameterType.freeBasicType) <> 0 Then
        result.status = C2FB_PARAMETER_CONVERSION_UNSUPPORTED
        Exit Sub
    End If
    Dim freeBasicType As String = resolvedParameterType.freeBasicType
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        Dim parameterSourceType As String
        For tokenIndex As Long = firstToken To typeEnd
            If parameterSourceType <> "" Then parameterSourceType &= " "
            parameterSourceType &= tokens(tokenIndex)
        Next
        Dim parameterStringMode As Long = _
            GenericStringOverrideModeForFieldInPolicy( _
                translation.genericC.policy, ownerName, "", _
                parameterName, argumentNumber)
        If parameterStringMode = 0 Then _
            parameterStringMode = GenericHeaderFbfrogStringDefaultMode( _
                translation, parameterSourceType, freeBasicType)
        If parameterStringMode > 0 AndAlso _
           resolvedParameterType.pointerCount = 0 Then
            Dim characterScalarType As String = _
                GenericHeaderFbfrogCharacterScalarType( _
                    translation, parameterSourceType, freeBasicType)
            If characterScalarType <> "" Then freeBasicType = characterScalarType
        End If
        freeBasicType = ApplyGenericStringOverrideModeInHeader( _
            translation.genericC.header, parameterStringMode, freeBasicType)
        If resolvedParameterType.pointerCount = 0 AndAlso _
           freeBasicType = "jmp_buf" Then
            If resolvedParameterType.isConst <> 0 Then _
                freeBasicType = "Const " & freeBasicType
            freeBasicType &= " Ptr"
        End If
    End If
    If referenceBaseConst <> 0 AndAlso Left(freeBasicType, 6) <> "Const " Then _
        freeBasicType = "Const " & freeBasicType
    If freeBasicType = "" OrElse freeBasicType = "void" Then Exit Sub
    SetC2fbParameterConversionResult( _
        result, argumentNumber, parameterName, freeBasicType, _
        isReferenceParameter)
End Sub
/' end of c2fb_parameters.bi '/
