/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_callbacks.bi

    Purpose:

        Preserve C callback signatures in FreeBASIC procedure-pointer types.

    Responsibilities:

        - Return typed status for non-callback, supported, and unsupported forms.
        - Read named and unnamed C procedure-pointer declarators.
        - Retain CDecl and explicit StdCall conventions on callback signatures.
        - Share signature metadata across parameters, typedefs, and members.
        - Lower nested CDecl and StdCall function-pointer results.

    This file intentionally does NOT contain:

        - Runtime callback adapters or C preprocessor evaluation.
        - Inference of missing signatures or calling conventions.
        - Full C declarator grammar or callback body-call lowering.
'/

' Callback types are local to the current serial file conversion. A procedure
' pointer is already a pointer type in BASIC; it does not need a Ptr suffix.
Private Sub ResetCBodyCallbackTypesInContext( _
    ByRef translation As C2fbTranslationContext _
)
    ReDim translation.body.callbacks(0 To 127)
    translation.body.callbackCount = 0
End Sub

Private Function NextCBodyGeneratedCallbackTypeName( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
) As String
    ' Imported aliases and source bindings share the generated type namespace.
    Dim candidateIndex As Long = translation.body.callbackCount
    While candidateIndex < MAX_C2FB_BODY_CALLBACK_TYPES
        Dim candidateName As String = _
            "c2fb_callback_" & Trim(Str(candidateIndex))
        Dim foldedName As String = LCase(candidateName)
        Dim nameIsUsed As Long = 0
        For callbackIndex As Long = 0 To translation.body.callbackCount - 1
            If LCase(translation.body.callbacks(callbackIndex).fbType) = foldedName Then
                nameIsUsed = -1
                Exit For
            End If
        Next
        For aliasIndex As Long = 0 To catalog.bodyTypeAliasCount - 1
            If LCase(catalog.bodyTypeAliases(aliasIndex).aliasName) = foldedName Then
                nameIsUsed = -1
                Exit For
            End If
        Next
        For aliasIndex As Long = 0 To translation.body.aliasCount - 1
            If LCase(translation.body.aliases(aliasIndex).name) = foldedName Then
                nameIsUsed = -1
                Exit For
            End If
        Next
        For recordIndex As Long = 0 To translation.body.recordBindingCount - 1
            If LCase(translation.body.recordBindings(recordIndex).fbName) = foldedName Then
                nameIsUsed = -1
                Exit For
            End If
        Next
        For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
            If LCase(translation.symbolTable.symbols(symbolIndex).freeBasicName) = _
               foldedName Then
                nameIsUsed = -1
                Exit For
            End If
        Next
        For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
            If LCase(translation.body.externalObjects(objectIndex).freeBasicName) = _
               foldedName OrElse _
               LCase(translation.body.externalObjects(objectIndex).storageName) = _
               foldedName Then
                nameIsUsed = -1
                Exit For
            End If
        Next
        For nameIndex As Long = 0 To catalog.callableNameCount - 1
            If LCase(catalog.callableNames(nameIndex)) = foldedName Then
                nameIsUsed = -1
                Exit For
            End If
        Next
        For nameIndex As Long = 0 To catalog.localDeclarationNameCount - 1
            If LCase(catalog.localDeclarationNames(nameIndex)) = foldedName Then
                nameIsUsed = -1
                Exit For
            End If
        Next
        If nameIsUsed = 0 Then Return candidateName
        candidateIndex += 1
    Wend
    ReportError("callbacks exceed the configured signature limit")
    Return ""
End Function

Private Sub IndexCBodyCallbackTypesFromCatalog( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
)
    For aliasIndex As Long = 0 To catalog.bodyTypeAliasCount - 1
        Dim freeBasicType As String = _
            Trim(catalog.bodyTypeAliases(aliasIndex).targetName)
        Dim isSub As Long = CInt(LCase(Left(freeBasicType, 4)) = "sub ") * -1
        If isSub = 0 AndAlso LCase(Left(freeBasicType, 9)) <> "function " Then _
            Continue For

        Dim parameterOpen As Long = InStr(freeBasicType, "(")
        If parameterOpen = 0 Then Continue For
        Dim parameterClose As Long = parameterOpen
        If ScanSimpleExpressionGroup( _
            freeBasicType, parameterClose, Asc("("), Asc(")")) = 0 Then _
            Continue For
        Dim parameterText As String = Trim(Mid( _
            freeBasicType, parameterOpen + 1, _
            parameterClose - parameterOpen - 2))
        Dim parameterCount As Long = 0
        Dim parameterTypes As String
        Dim isVariadic As Long = 0
        If parameterText <> "" Then
            Dim parameters() As String
            Dim parameterPartCount As Long
            If SplitSimpleCList( _
                parameterText, parameters(), parameterPartCount) = 0 Then _
                Continue For
            For parameterIndex As Long = 0 To parameterPartCount - 1
                Dim parameter As String = Trim(parameters(parameterIndex))
                If parameter = "..." Then
                    If parameterIndex <> parameterPartCount - 1 Then _
                        parameterCount = -1
                    isVariadic = -1
                    Continue For
                End If
                Dim asPosition As Long = InStr(LCase(parameter), " as ")
                If asPosition = 0 Then
                    parameterCount = -1
                    Exit For
                End If
                Dim parameterType As String = Trim(Mid(parameter, asPosition + 4))
                If parameterType = "" OrElse InStr(LCase(parameterType), "function ") <> 0 OrElse _
                   InStr(LCase(parameterType), "sub ") <> 0 Then
                    parameterCount = -1
                    Exit For
                End If
                parameterTypes &= parameterType & "|"
                parameterCount += 1
            Next
        End If
        If parameterCount < 0 Then Continue For

        Dim returnType As String = "void"
        If isSub = 0 Then
            Dim signatureTail As String = Trim(Mid(freeBasicType, parameterClose))
            If LCase(Left(signatureTail, 3)) <> "as " Then Continue For
            returnType = Trim(Mid(signatureTail, 4))
            If returnType = "" Then Continue For
        End If

        Dim alreadyRegistered As Long = 0
        For callbackIndex As Long = 0 To translation.body.callbackCount - 1
            If translation.body.callbacks(callbackIndex).fbType = _
                   catalog.bodyTypeAliases(aliasIndex).aliasName OrElse _
               translation.body.callbacks(callbackIndex).declaration = freeBasicType Then
                alreadyRegistered = -1
                Exit For
            End If
        Next
        If alreadyRegistered <> 0 Then Continue For
        If translation.body.callbackCount >= _
           MAX_C2FB_BODY_CALLBACK_TYPES Then _
            ReportError("callbacks exceed the configured signature limit")
        If translation.body.callbackCount > UBound(translation.body.callbacks) Then _
            ReDim Preserve translation.body.callbacks( _
                0 To UBound(translation.body.callbacks) * 2 + 1)
        With translation.body.callbacks(translation.body.callbackCount)
            .fbType = catalog.bodyTypeAliases(aliasIndex).aliasName
            .declaration = freeBasicType
            .returnType = returnType
            .parameterTypes = parameterTypes
            .parameterCount = parameterCount
            .isVariadic = isVariadic
        End With
        translation.body.callbackCount += 1
    Next
End Sub

Private Function CBodyCallbackIndexInContext( _
    ByRef translation As C2fbTranslationContext, ByVal fbType As String _
) As Long
    For i As Long = 0 To translation.body.callbackCount - 1
        If translation.body.callbacks(i).fbType = fbType OrElse _
           translation.body.callbacks(i).declaration = fbType Then Return i
    Next
    Return -1
End Function

Private Function CBodyCallbackDeclarationInContext( _
    ByRef translation As C2fbTranslationContext, ByVal fbType As String _
) As String
    Dim index As Long = CBodyCallbackIndexInContext(translation, fbType)
    If index < 0 Then Return ""
    Return translation.body.callbacks(index).declaration
End Function

Private Function CBodyCallbackPointerMappingInContext( _
    ByVal typeMappingKind As C2fbTypeMappingKind _
) As C2fbPointerMappingPolicy
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then _
        Return C2FB_POINTER_MAPPING_OPAQUE
    Return C2FB_POINTER_MAPPING_PRESERVE
End Function

Private Function CBodyIsCallbackQualifierOrConvention(ByVal token As String) As Long
    Select Case LCase(token)
    Case "const", "volatile", "restrict", "__restrict", "__restrict__", _
         "cdecl", "__cdecl", "__cdecl__", "stdcall", "__stdcall", _
         "__stdcall__", "winapi", "apientry", "ntapi", "far", "near"
        Return -1
    End Select
    Return 0
End Function

Private Function CBodyStdCallTokenCount( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long _
) As Long
    Dim result As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        Select Case LCase(tokens(tokenIndex))
        Case "stdcall", "__stdcall", "__stdcall__", "winapi", "apientry", "ntapi"
            result += 1
        End Select
    Next
    Return result
End Function

Private Function CBodyCallbackCallConv( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByVal pointerOpen As Long, ByVal pointerClose As Long, _
    ByVal parameterClose As Long _
) As String
    Dim sawStdCall As Long = 0
    Dim sawCDecl As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        If (tokenIndex < pointerOpen) OrElse _
           (tokenIndex > pointerOpen AndAlso tokenIndex < pointerClose) OrElse _
           tokenIndex > parameterClose Then
            Select Case LCase(tokens(tokenIndex))
            Case "stdcall", "__stdcall", "__stdcall__", "winapi", "apientry", "ntapi"
                sawStdCall = -1
            Case "cdecl", "__cdecl", "__cdecl__"
                sawCDecl = -1
            End Select
        End If
    Next
    If sawCDecl <> 0 AndAlso sawStdCall <> 0 Then Return "Invalid"
    If sawStdCall <> 0 Then Return "StdCall"
    Return "CDecl"
End Function

Private Function RegisterCBodyCallbackTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByVal returnType As String, _
    ByVal parameterTypes As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long _
) As String
    Dim callbackIndex As Long = _
        CBodyCallbackIndexInContext(translation, declaration)
    If callbackIndex < 0 Then
        If translation.body.callbackCount >= _
           MAX_C2FB_BODY_CALLBACK_TYPES Then _
            ReportError("callbacks exceed the configured signature limit")
        If translation.body.callbackCount > UBound(translation.body.callbacks) Then _
            ReDim Preserve translation.body.callbacks( _
                0 To UBound(translation.body.callbacks) * 2 + 1)
        callbackIndex = translation.body.callbackCount
        With translation.body.callbacks(callbackIndex)
            .fbType = NextCBodyGeneratedCallbackTypeName(translation, catalog)
            .declaration = declaration
            .returnType = returnType
            .parameterTypes = parameterTypes
            .parameterCount = parameterCount
            .isVariadic = isVariadic
        End With
        translation.body.callbackCount += 1
    End If
    Return translation.body.callbacks(callbackIndex).fbType
End Function

Private Function BuildNestedCBodyCallbackParametersInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    tokens() As String, ByVal parameterOpen As Long, _
    ByVal lastToken As Long, ByVal depth As Long, _
    ByVal typeMappingKind As C2fbTypeMappingKind, _
    ByRef parameters As String, ByRef parameterTypes As String, _
    ByRef parameterCount As Long, ByRef isVariadic As Long, _
    ByRef parameterClose As Long _
) As Long
    parameters = ""
    parameterTypes = ""
    parameterCount = 0
    isVariadic = 0
    Dim closePosition As Long = parameterOpen
    If SkipCDeclaratorGroup( _
        tokens(), closePosition, lastToken, "(", ")") = 0 Then Return 0
    parameterClose = closePosition - 1
    If parameterOpen + 1 >= parameterClose Then Return -1
    If parameterOpen + 2 = parameterClose AndAlso _
       tokens(parameterOpen + 1) = "void" Then Return -1

    Dim parameterRanges() As C2fbTokenRangeModel
    Dim parameterRangeCount As Long
    If SplitC2fbTokenList( _
        tokens(), parameterOpen + 1, parameterClose - 1, _
        parameterRanges(), parameterRangeCount) = 0 Then Return 0

    For rangeIndex As Long = 0 To parameterRangeCount - 1
        Dim firstParameterToken As Long = parameterRanges(rangeIndex).firstToken
        Dim lastParameterToken As Long = parameterRanges(rangeIndex).lastToken
        If firstParameterToken = lastParameterToken AndAlso _
           tokens(firstParameterToken) = "..." Then
            If parameterCount = 0 OrElse rangeIndex <> parameterRangeCount - 1 Then Return 0
            isVariadic = -1
            Exit For
        End If

        Dim nestedCallback As C2fbCallbackTypeResultModel
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, tokens(), firstParameterToken, _
            lastParameterToken, nestedCallback, depth + 1, typeMappingKind)
        If nestedCallback.status = C2FB_CALLBACK_TYPE_UNSUPPORTED Then Return 0

        Dim nestedType As String
        If nestedCallback.status = C2FB_CALLBACK_TYPE_CONVERTED Then
            nestedType = nestedCallback.freeBasicType
            If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then _
                nestedType = CBodyCallbackDeclarationInContext( _
                    translation, nestedType)
            If nestedType = "" Then Return 0
        End If

        Dim parameterName As String = nestedCallback.callbackName
        If parameterName = "" Then _
            parameterName = "arg" & Trim(Str(parameterCount))
        Dim parameterType As String
        If nestedType <> "" Then
            parameterType = nestedType
            If parameterCount > 0 Then parameters &= ", "
            parameters &= "ByVal " & parameterName & " As " & parameterType
        Else
            Dim parameterResult As C2fbParameterConversionResultModel
            ConvertParameterInContext( _
                translation, catalog, tokens(), firstParameterToken, _
                lastParameterToken, parameterCount, parameterResult, _
                C2FB_POINTER_MAPPING_OPAQUE, typeMappingKind)
            If parameterResult.status = C2FB_PARAMETER_CONVERSION_VARIADIC Then
                If parameterCount = 0 OrElse rangeIndex <> parameterRangeCount - 1 Then Return 0
                isVariadic = -1
                Exit For
            ElseIf parameterResult.status <> C2FB_PARAMETER_CONVERSION_CONVERTED Then
                Return 0
            End If
            parameterName = parameterResult.sourceName
            parameterType = parameterResult.freeBasicType
            If parameterType = "" Then Return 0

            Dim typeEnd As Long = lastParameterToken
            If typeEnd >= firstParameterToken AndAlso _
               tokens(typeEnd) = parameterName Then typeEnd -= 1
            If typeMappingKind = C2FB_TYPE_MAPPING_BODY AndAlso _
               InStr(parameterType, " Ptr") = 0 AndAlso _
               IsCBodyCallbackTypeInContext(translation, parameterType) = 0 AndAlso _
               C2fbTypeRecognitionStatusInContext( _
                   translation, catalog, tokens(), firstParameterToken, typeEnd) <> _
               C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0

            If parameterCount > 0 Then parameters &= ", "
            parameters &= "ByVal " & parameterResult.freeBasicDeclaration
        End If

        parameterTypes &= parameterType & "|"
        parameterCount += 1
    Next

    If isVariadic <> 0 Then parameters &= ", ..."
    Return -1
End Function

Private Function FindNestedCallbackPointerGroupOpen( _
    tokens() As String, ByVal firstToken As Long, ByVal groupClose As Long _
) As Long
    If groupClose < firstToken OrElse tokens(groupClose) <> ")" Then Return -1
    Dim nesting As Long = 0
    For tokenIndex As Long = groupClose To firstToken Step -1
        If tokens(tokenIndex) = ")" Then
            nesting += 1
        ElseIf tokens(tokenIndex) = "(" Then
            nesting -= 1
            If nesting = 0 Then Return tokenIndex
            If nesting < 0 Then Return -1
        End If
    Next
    Return -1
End Function

Private Function NestedCallbackCallConventionTokenKind( _
    ByVal token As String _
) As Long
    Select Case LCase(token)
    Case "stdcall", "__stdcall", "__stdcall__", "winapi", "apientry", "ntapi"
        Return 2
    Case "cdecl", "__cdecl", "__cdecl__"
        Return 1
    End Select
    Return 0
End Function

Private Function NestedCallbackAttributeCallConvention( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long _
) As Long
    Dim result As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        Dim tokenKind As Long = _
            NestedCallbackCallConventionTokenKind(tokens(tokenIndex))
        If tokenKind = 0 Then Continue For
        If result <> 0 AndAlso result <> tokenKind Then Return -1
        result = tokenKind
    Next
    Return result
End Function

Private Function NestedCBodyCallbackCallConv( _
    tokens() As String, ByVal firstToken As Long, _
    ByVal parameterOpen As Long _
) As String
    Dim pointerClose As Long = parameterOpen - 1
    Dim pointerOpen As Long = FindNestedCallbackPointerGroupOpen( _
        tokens(), firstToken, pointerClose)
    If pointerOpen < firstToken Then Return "Invalid"

    Dim sawStdCall As Long = 0
    Dim sawCDecl As Long = 0
    Dim nesting As Long = 0
    Dim tokenIndex As Long = pointerOpen + 1
    While tokenIndex < pointerClose
        If nesting = 0 AndAlso _
           (tokens(tokenIndex) = "__attribute__" OrElse _
            tokens(tokenIndex) = "__declspec") AndAlso _
           tokenIndex + 1 < pointerClose AndAlso tokens(tokenIndex + 1) = "(" Then
            Dim attributePosition As Long = tokenIndex + 1
            If SkipCDeclaratorGroup( _
                tokens(), attributePosition, pointerClose - 1, "(", ")") = 0 Then _
                Return "Invalid"
            Dim attributeKind As Long = NestedCallbackAttributeCallConvention( _
                tokens(), tokenIndex + 2, attributePosition - 2)
            If attributeKind < 0 Then Return "Invalid"
            If attributeKind = 2 Then sawStdCall = -1
            If attributeKind = 1 Then sawCDecl = -1
            tokenIndex = attributePosition
            Continue While
        End If

        If nesting = 0 Then
            Dim tokenKind As Long = _
                NestedCallbackCallConventionTokenKind(tokens(tokenIndex))
            If tokenKind = 2 Then sawStdCall = -1
            If tokenKind = 1 Then sawCDecl = -1
        End If
        If tokens(tokenIndex) = "(" Then
            nesting += 1
        ElseIf tokens(tokenIndex) = ")" Then
            nesting -= 1
            If nesting < 0 Then Return "Invalid"
        End If
        tokenIndex += 1
    Wend

    If nesting <> 0 OrElse (sawCDecl <> 0 AndAlso sawStdCall <> 0) Then _
        Return "Invalid"
    If sawStdCall <> 0 Then Return "StdCall"
    Return "CDecl"
End Function

Private Function BuildCBodyCallbackReturnChainInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, tokens() As String, _
    ByVal firstToken As Long, ByVal lastToken As Long, _
    ByVal functionOpenPositions As String, ByVal baseReturnType As String, _
    ByVal depth As Long, ByVal typeMappingKind As C2fbTypeMappingKind, _
    ByRef outerCallbackType As String, ByRef fullDeclaration As String _
) As Long
    outerCallbackType = ""
    fullDeclaration = ""
    If functionOpenPositions = "" OrElse baseReturnType = "" OrElse _
       depth + Len(functionOpenPositions) > 8 Then Return 0

    Dim returnType As String = baseReturnType
    ' Later function suffixes return the inner callback types, so lower them first.
    For functionIndex As Long = Len(functionOpenPositions) To 1 Step -1
        Dim parameterOpen As Long = _
            Asc(functionOpenPositions, functionIndex) - 1
        Dim parameters As String
        Dim parameterTypes As String
        Dim parameterCount As Long
        Dim isVariadic As Long
        Dim parameterClose As Long
        If BuildNestedCBodyCallbackParametersInContext( _
            translation, catalog, tokens(), parameterOpen, lastToken, _
            depth, typeMappingKind, parameters, parameterTypes, _
            parameterCount, isVariadic, parameterClose) = 0 Then Return 0

        Dim callbackCallConv As String = NestedCBodyCallbackCallConv( _
            tokens(), firstToken, parameterOpen)
        If callbackCallConv = "Invalid" OrElse _
           (isVariadic <> 0 AndAlso callbackCallConv <> "CDecl") Then Return 0

        Dim callbackDeclaration As String
        If returnType = "void" Then
            callbackDeclaration = "Sub " & callbackCallConv & _
                "(" & parameters & ")"
        Else
            callbackDeclaration = "Function " & callbackCallConv & _
                "(" & parameters & ") As " & returnType
        End If
        outerCallbackType = RegisterCBodyCallbackTypeInContext( _
            translation, catalog, callbackDeclaration, returnType, parameterTypes, _
            parameterCount, isVariadic)
        If outerCallbackType = "" Then Return 0
        returnType = CBodyCallbackDeclarationInContext( _
            translation, outerCallbackType)
        If returnType = "" Then Return 0
    Next

    fullDeclaration = returnType
    Return -1
End Function

Private Function ResolveNestedCBodyCallbackTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef declarator As C2fbDeclaratorModel, ByVal depth As Long, _
    ByVal typeMappingKind As C2fbTypeMappingKind, _
    ByRef result As C2fbCallbackTypeResultModel _
) As Long
    result.status = C2FB_CALLBACK_TYPE_UNSUPPORTED
    result.callbackName = declarator.name
    result.freeBasicType = ""
    result.pointerDepth = 1

    ' A pointer to a function returning another function pointer repeats the
    ' C binding pair P-F. Build those result layers from the inside out.
    If depth >= 8 OrElse Len(declarator.bindingOrder) < 4 OrElse _
       Len(declarator.bindingOrder) Mod 2 <> 0 OrElse _
       Len(declarator.functionOpenPositions) <> Len(declarator.bindingOrder) \ 2 OrElse _
       CBodyStdCallTokenCount( _
           tokens(), firstToken, declarator.firstToken - 1) > 0 Then Return 0
    For operatorIndex As Long = 0 To Len(declarator.bindingOrder) - 1 Step 2
        If Mid(declarator.bindingOrder, operatorIndex + 1, 2) <> "PF" Then Return 0
    Next

    Dim returnTypeResult As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        translation, catalog, tokens(), firstToken, _
        declarator.firstToken - 1, returnTypeResult, _
        CBodyCallbackPointerMappingInContext(typeMappingKind), typeMappingKind)
    If returnTypeResult.status <> C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
       returnTypeResult.pointerCount <> 0 OrElse _
       returnTypeResult.freeBasicType = "" Then Return 0
    Dim outerCallbackType As String
    Dim callbackDeclaration As String
    If BuildCBodyCallbackReturnChainInContext( _
        translation, catalog, tokens(), firstToken, lastToken, _
        declarator.functionOpenPositions, returnTypeResult.freeBasicType, _
        depth, typeMappingKind, outerCallbackType, callbackDeclaration) = 0 Then Return 0

    result.freeBasicType = outerCallbackType
    result.status = C2FB_CALLBACK_TYPE_CONVERTED
    Return -1
End Function

Private Function CBodyBuiltinExtensionCallbackTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
) As String
    ' main.c declares sqlite3BuiltinExtensions as a file-local callback array.
    ' Keep its signature available even though it is not a parameter or record field.
    Dim declaration As String = _
        "Function CDecl(ByVal arg0 As sqlite3 Ptr) As c2fb_c_int"
    Dim callbackIndex As Long = CBodyCallbackIndexInContext(translation, declaration)
    If callbackIndex < 0 Then
        If translation.body.callbackCount > UBound(translation.body.callbacks) Then _
            ReDim Preserve translation.body.callbacks(0 To UBound(translation.body.callbacks) * 2 + 1)
        callbackIndex = translation.body.callbackCount
        With translation.body.callbacks(callbackIndex)
            .fbType = NextCBodyGeneratedCallbackTypeName(translation, catalog)
            .declaration = declaration
            .returnType = "c2fb_c_int"
            .parameterTypes = "sqlite3 Ptr|"
            .parameterCount = 1
            .isVariadic = 0
        End With
        translation.body.callbackCount += 1
    End If
    Return translation.body.callbacks(callbackIndex).fbType
End Function

Private Function IsCBodyCallbackTypeInContext( _
    ByRef translation As C2fbTranslationContext, ByVal fbType As String _
) As Long
    Return CInt(Left(fbType, 9) = "Function " OrElse Left(fbType, 4) = "Sub " OrElse _
                CBodyCallbackIndexInContext(translation, fbType) >= 0)
End Function

Private Function CBodyCallbackParameterTypeAtIndexInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal callbackIndex As Long, ByVal parameterIndex As Long _
) As String
    If callbackIndex < 0 OrElse _
       callbackIndex >= translation.body.callbackCount OrElse _
       parameterIndex < 0 OrElse _
       parameterIndex >= translation.body.callbacks(callbackIndex).parameterCount Then _
        Return ""
    Dim parameterTypes As String = _
        translation.body.callbacks(callbackIndex).parameterTypes
    Dim start As Long = 1
    For index As Long = 0 To parameterIndex - 1
        start = InStr(start, parameterTypes, "|") + 1
        If start <= 1 Then Return ""
    Next
    Dim finish As Long = InStr(start, parameterTypes, "|")
    If finish = 0 Then Return ""
    Return Mid(parameterTypes, start, finish - start)
End Function

Private Function CBodyCallbackParameterTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal fbType As String, ByVal parameterIndex As Long _
) As String
    Dim callbackIndex As Long = _
        CBodyCallbackIndexInContext(translation, fbType)
    Return CBodyCallbackParameterTypeAtIndexInContext( _
        translation, callbackIndex, parameterIndex)
End Function

Private Function CBodyCallbackTypesCompatibleInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal leftType As String, ByVal rightType As String, _
    ByVal depth As Long _
) As Long
    If LCase(leftType) = LCase(rightType) Then Return -1
    If depth > 8 Then Return 0

    Dim leftQualifier As String
    Dim rightQualifier As String
    If Left(leftType, 6) = "Const " Then
        leftQualifier = "Const "
        leftType = Mid(leftType, 7)
    End If
    If Left(rightType, 6) = "Const " Then
        rightQualifier = "Const "
        rightType = Mid(rightType, 7)
    End If
    If leftQualifier <> rightQualifier Then Return 0

    Dim leftPointerCount As Long = 0
    Dim rightPointerCount As Long = 0
    While Right(leftType, 4) = " Ptr"
        leftType = Left(leftType, Len(leftType) - 4)
        leftPointerCount += 1
    Wend
    While Right(rightType, 4) = " Ptr"
        rightType = Left(rightType, Len(rightType) - 4)
        rightPointerCount += 1
    Wend
    If leftPointerCount <> rightPointerCount Then Return 0

    Dim leftCallback As Long = CBodyCallbackIndexInContext(translation, leftType)
    Dim rightCallback As Long = CBodyCallbackIndexInContext(translation, rightType)
    If leftCallback < 0 OrElse rightCallback < 0 Then
        If leftCallback >= 0 OrElse rightCallback >= 0 Then Return 0
        Dim normalizedLeftType As String = _
            NormalizeFbBodyType(catalog, leftType)
        Dim normalizedRightType As String = _
            NormalizeFbBodyType(catalog, rightType)
        If LCase(normalizedLeftType) = LCase(normalizedRightType) Then Return -1

        ' Different FreeBASIC spellings can represent the same C integer ABI
        ' type, for example UInteger and CULong for size_t on LP64 targets.
        Dim leftWidth As Long = _
            SimpleIntegerWidthInBits(catalog, normalizedLeftType)
        Dim rightWidth As Long = _
            SimpleIntegerWidthInBits(catalog, normalizedRightType)
        If leftWidth > 0 AndAlso leftWidth = rightWidth AndAlso _
           SimpleArithmeticTypeIsUnsigned( _
               catalog, normalizedLeftType) = _
           SimpleArithmeticTypeIsUnsigned( _
               catalog, normalizedRightType) Then Return -1
        Return 0
    End If

    With translation.body.callbacks(leftCallback)
        If .parameterCount <> translation.body.callbacks(rightCallback).parameterCount OrElse _
           .isVariadic <> translation.body.callbacks(rightCallback).isVariadic Then Return 0
        If CBodyCallbackTypesCompatibleInContext( _
            translation, catalog, .returnType, _
            translation.body.callbacks(rightCallback).returnType, depth + 1) = 0 Then Return 0
        For parameterIndex As Long = 0 To .parameterCount - 1
            If CBodyCallbackTypesCompatibleInContext( _
                translation, catalog, _
                CBodyCallbackParameterTypeInContext( _
                    translation, .fbType, parameterIndex), _
                CBodyCallbackParameterTypeInContext( _
                    translation, translation.body.callbacks(rightCallback).fbType, _
                    parameterIndex), depth + 1) = 0 Then Return 0
        Next
    End With
    Return -1
End Function

Private Function HasPotentialCallbackDeclarator( _
    tokens() As String, ByVal opening As Long, ByVal lastToken As Long _
) As Long
    Dim nesting As Long = 1
    Dim hasPointer As Long = 0
    For tokenIndex As Long = opening + 1 To lastToken
        If tokens(tokenIndex) = "(" Then
            nesting += 1
        ElseIf tokens(tokenIndex) = ")" Then
            nesting -= 1
            If nesting = 0 Then
                If hasPointer <> 0 AndAlso tokenIndex < lastToken AndAlso _
                   tokens(tokenIndex + 1) = "(" Then Return -1
                Return 0
            End If
        ElseIf tokens(tokenIndex) = "*" Then
            hasPointer = -1
        End If
    Next
    Return 0
End Function

Private Function IsCallbackReturnTypePrefix( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long _
) As Long
    If firstToken > lastToken Then Return 0
    Dim foundType As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        If tokens(tokenIndex) = "*" Then Continue For
        If IsIdentifierToken(tokens(tokenIndex)) = 0 Then Return 0
        Select Case LCase(tokens(tokenIndex))
        Case "auto", "extern", "inline", "__inline", "__inline__", _
             "register", "static", "typedef", "const", "volatile", _
             "restrict", "_noreturn", "__thread", "__restrict", _
             "__restrict__", "cdecl", "__cdecl", "__cdecl__", _
             "stdcall", "__stdcall", "__stdcall__", "winapi", _
             "apientry", "ntapi"
            Continue For
        End Select
        If IsAttributeToken(tokens(tokenIndex)) <> 0 Then Continue For
        foundType = -1
    Next
    Return foundType
End Function

Private Sub ResolveCBodyCallbackTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef result As C2fbCallbackTypeResultModel, ByVal depth As Long, _
    ByVal typeMappingKind As C2fbTypeMappingKind, _
    ByVal allowPointerLayers As Long = 0, _
    ByVal allowFunctionParameterDecay As Long = 0 _
)
    result.status = C2FB_CALLBACK_TYPE_NOT_CALLBACK
    result.callbackName = ""
    result.freeBasicType = ""
    result.pointerDepth = 0
    Dim opening As Long = -1
    Dim pointerClose As Long = -1
    Dim pointerCount As Long = 0
    Dim callbackSignatureLastToken As Long = lastToken
    Dim sawCallbackDeclarator As Long = 0

    If allowFunctionParameterDecay <> 0 Then
        ' C adjusts a function parameter to a pointer before the function body
        ' can call it. Accept both `fn (T)` and the redundant `(fn (T))` form.
        For i As Long = firstToken + 1 To lastToken - 1
            If IsCallbackReturnTypePrefix(tokens(), firstToken, i - 1) = 0 Then Continue For
            Dim callbackNameIndex As Long = -1
            Dim callbackParameterOpen As Long = -1
            Dim hasOuterGrouping As Long = 0
            If tokens(i) = "(" AndAlso i + 2 <= lastToken AndAlso _
               IsIdentifierToken(tokens(i + 1)) <> 0 AndAlso _
               tokens(i + 2) = "(" Then
                callbackNameIndex = i + 1
                callbackParameterOpen = i + 2
                hasOuterGrouping = -1
            ElseIf IsIdentifierToken(tokens(i)) <> 0 AndAlso _
                   i + 1 <= lastToken AndAlso tokens(i + 1) = "(" Then
                callbackNameIndex = i
                callbackParameterOpen = i + 1
            Else
                Continue For
            End If

            Dim parameterNesting As Long = 1
            Dim callbackParameterClose As Long = -1
            For parameterToken As Long = callbackParameterOpen + 1 To lastToken
                If tokens(parameterToken) = "(" Then
                    parameterNesting += 1
                ElseIf tokens(parameterToken) = ")" Then
                    parameterNesting -= 1
                    If parameterNesting = 0 Then
                        callbackParameterClose = parameterToken
                        Exit For
                    End If
                End If
            Next
            If hasOuterGrouping <> 0 Then
                If callbackParameterClose <> lastToken - 1 OrElse _
                   tokens(lastToken) <> ")" Then Continue For
            ElseIf callbackParameterClose <> lastToken Then
                Continue For
            End If
            opening = i
            pointerClose = callbackNameIndex
            pointerCount = 1
            callbackSignatureLastToken = callbackParameterClose
            result.pointerDepth = 1
            result.callbackName = tokens(callbackNameIndex)
            result.status = C2FB_CALLBACK_TYPE_UNSUPPORTED
            Exit For
        Next
    End If

    For i As Long = firstToken To lastToken - 1
        If opening >= 0 Then Exit For
        If tokens(i) <> "(" Then Continue For
        If HasPotentialCallbackDeclarator( _
            tokens(), i, lastToken) <> 0 Then _
            sawCallbackDeclarator = -1
        Dim candidatePosition As Long = i
        Dim candidate As C2fbDeclaratorModel
        If ParseCDeclaratorModel( _
            tokens(), candidatePosition, lastToken, candidate, 0, -1) = 0 Then Continue For
        If candidatePosition <= lastToken AndAlso _
           tokens(candidatePosition) = ";" Then candidatePosition += 1
        If candidatePosition <> lastToken + 1 OrElse _
           IsCallbackReturnTypePrefix( _
               tokens(), firstToken, i - 1) = 0 Then Continue For

        Dim functionOperatorIndex As Long = -1
        Dim functionOperatorCount As Long = 0
        Dim pointerOnlyDeclarator As Long = -1
        For operatorIndex As Long = 0 To candidate.operatorCount - 1
            If candidate.operatorKind(operatorIndex) = _
               C2FB_DECLARATOR_FUNCTION Then
                functionOperatorCount += 1
                functionOperatorIndex = operatorIndex
            ElseIf candidate.operatorKind(operatorIndex) <> _
                   C2FB_DECLARATOR_POINTER Then
                pointerOnlyDeclarator = 0
            End If
        Next
        If functionOperatorCount = 1 AndAlso pointerOnlyDeclarator <> 0 AndAlso _
           functionOperatorIndex > 0 Then
            Dim callbackPointerDepth As Long = functionOperatorIndex
            If callbackPointerDepth = 1 OrElse allowPointerLayers <> 0 Then
                Dim groupEnd As Long = i + 1
                Dim nesting As Long = 1
                While groupEnd <= lastToken AndAlso nesting > 0
                    If tokens(groupEnd) = "(" Then
                        nesting += 1
                    ElseIf tokens(groupEnd) = ")" Then
                        nesting -= 1
                    End If
                    If nesting > 0 Then groupEnd += 1
                Wend
                If nesting = 0 AndAlso groupEnd < lastToken AndAlso _
                   tokens(groupEnd + 1) = "(" AndAlso _
                   candidate.firstFunctionOpenToken = groupEnd + 1 Then
                    opening = i
                    pointerClose = groupEnd
                    pointerCount = callbackPointerDepth
                    result.pointerDepth = callbackPointerDepth
                    result.callbackName = candidate.name
                    result.status = C2FB_CALLBACK_TYPE_UNSUPPORTED
                    Exit For
                End If
            End If
        End If

        If candidatePosition = lastToken + 1 AndAlso _
           Len(candidate.bindingOrder) > 2 AndAlso _
           Left(candidate.bindingOrder, 1) = "P" AndAlso _
           IsCallbackReturnTypePrefix( _
               tokens(), firstToken, i - 1) <> 0 Then
            result.status = C2FB_CALLBACK_TYPE_UNSUPPORTED
            ResolveNestedCBodyCallbackTypeInContext( _
                translation, catalog, tokens(), firstToken, lastToken, _
                candidate, depth, typeMappingKind, result)
            Exit Sub
        End If
        If opening >= 0 Then Exit For
        If candidate.operatorCount <> 2 OrElse _
           candidate.operatorKind(0) <> C2FB_DECLARATOR_POINTER OrElse _
           candidate.operatorKind(1) <> C2FB_DECLARATOR_FUNCTION Then Continue For
        If candidatePosition <> lastToken + 1 Then Continue For

        Dim groupEnd As Long = i + 1
        Dim nesting As Long = 1
        While groupEnd <= lastToken AndAlso nesting > 0
            If tokens(groupEnd) = "(" Then
                nesting += 1
            ElseIf tokens(groupEnd) = ")" Then
                nesting -= 1
            End If
            If nesting > 0 Then groupEnd += 1
        Wend
        If nesting <> 0 OrElse groupEnd >= lastToken OrElse _
           tokens(groupEnd + 1) <> "(" OrElse _
           candidate.firstFunctionOpenToken <> groupEnd + 1 Then Continue For

        ' ParseCDeclaratorModel has already proved this is exactly one pointer
        ' to one function. Do not require the identifier to be the only token
        ' between the visible parentheses: C permits redundant grouping such
        ' as void (((*callback)))(void).
        opening = i
        pointerClose = groupEnd
        pointerCount = 1
        result.pointerDepth = 1
        result.callbackName = candidate.name
        result.status = C2FB_CALLBACK_TYPE_UNSUPPORTED
        Exit For
    Next
    If opening <= firstToken Then
        If sawCallbackDeclarator <> 0 Then _
            result.status = C2FB_CALLBACK_TYPE_UNSUPPORTED
        Exit Sub
    End If
    If depth >= 8 Then Exit Sub
    If pointerCount <= 0 OrElse _
       (pointerCount <> 1 AndAlso allowPointerLayers = 0) OrElse _
       pointerClose + 1 > callbackSignatureLastToken OrElse _
       tokens(pointerClose + 1) <> "(" Then Exit Sub
    Dim parameterOpen As Long = pointerClose + 1
    Dim resolvedReturnType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel(translation, catalog, _
        tokens(), firstToken, opening - 1, resolvedReturnType, _
        CBodyCallbackPointerMappingInContext(typeMappingKind), typeMappingKind)
    If resolvedReturnType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Exit Sub
    Dim returnType As String = resolvedReturnType.freeBasicType
    Dim pointers As Long = resolvedReturnType.pointerCount
    If typeMappingKind = C2FB_TYPE_MAPPING_BODY AndAlso pointers = 0 AndAlso _
       C2fbTypeRecognitionStatusInContext( _
           translation, catalog, tokens(), firstToken, opening - 1) <> _
       C2FB_TYPE_RESOLUTION_RESOLVED Then Exit Sub
    Dim parameters As String
    Dim parameterTypes As String
    Dim parameterCount As Long = 0
    Dim isVariadic As Long = 0
    Dim start As Long = parameterOpen + 1
    Dim nesting As Long = 0
    Dim foundEnd As Long = 0
    Dim parameterClose As Long = -1
    For i As Long = start To callbackSignatureLastToken
        If tokens(i) = "(" Then nesting += 1
        Dim atEnd As Long = CInt(tokens(i) = ")" AndAlso nesting = 0)
        If tokens(i) = ")" AndAlso nesting > 0 Then
            nesting -= 1
            Continue For
        End If
        If atEnd <> 0 OrElse (tokens(i) = "," AndAlso nesting = 0) Then
            If start <= i - 1 AndAlso tokens(start) = "..." Then
                If start <> i - 1 OrElse atEnd = 0 OrElse parameterCount = 0 Then Exit Sub
                isVariadic = -1
            Else
                Dim parameterResult As C2fbParameterConversionResultModel
                Dim parameterName As String = "arg" & Trim(Str(parameterCount))
                Dim nestedCallback As C2fbCallbackTypeResultModel
                ResolveCBodyCallbackTypeInContext( _
                    translation, catalog, tokens(), start, i - 1, _
                    nestedCallback, depth + 1, typeMappingKind)
                If nestedCallback.status = C2FB_CALLBACK_TYPE_UNSUPPORTED Then Exit Sub
                Dim nestedType As String = ""
                If nestedCallback.status = C2FB_CALLBACK_TYPE_CONVERTED Then _
                    nestedType = nestedCallback.freeBasicType
                parameterName = nestedCallback.callbackName
                If parameterName = "" Then parameterName = "arg" & Trim(Str(parameterCount))
                If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER AndAlso nestedType <> "" Then _
                    nestedType = CBodyCallbackDeclarationInContext( _
                        translation, nestedType)
                If nestedCallback.status = C2FB_CALLBACK_TYPE_CONVERTED AndAlso _
                   nestedType = "" Then Exit Sub
                Dim parameterStdCallCount As Long = CBodyStdCallTokenCount( _
                    tokens(), start, i - 1)
                If parameterStdCallCount > 0 Then
                    If nestedType = "" Then Exit Sub
                    Dim nestedDeclaration As String = _
                        CBodyCallbackDeclarationInContext(translation, nestedType)
                    If CDeclarationStdCallCount(nestedDeclaration) <> parameterStdCallCount Then _
                        Exit Sub
                End If
                If nestedType <> "" Then
                    parameterResult.status = C2FB_PARAMETER_CONVERSION_CONVERTED
                    parameterResult.sourceName = parameterName
                    If parameterResult.sourceName = "" Then _
                        parameterResult.sourceName = "arg" & Trim(Str(parameterCount))
                    parameterResult.argumentName = "arg" & Trim(Str(parameterCount))
                    parameterResult.freeBasicType = nestedType
                    parameterResult.freeBasicDeclaration = _
                        parameterResult.argumentName & " As " & nestedType
                Else
                    ' Nested function pointers were handled above. Preserve
                    ' known object-pointer types so callback aliases agree with
                    ' their declared C targets; unresolved pointers still map
                    ' to Any Ptr through the body type resolver.
                    ConvertParameterInContext( _
                        translation, catalog, tokens(), start, i - 1, _
                        parameterCount, parameterResult, _
                CBodyCallbackPointerMappingInContext(typeMappingKind), _
                typeMappingKind, result.callbackName)
                End If
                If parameterResult.status = C2FB_PARAMETER_CONVERSION_UNSUPPORTED OrElse _
                   parameterResult.status = C2FB_PARAMETER_CONVERSION_INVALID OrElse _
                   parameterResult.status = C2FB_PARAMETER_CONVERSION_VARIADIC Then Exit Sub
                If parameterResult.status = C2FB_PARAMETER_CONVERSION_CONVERTED Then
                    parameterName = parameterResult.sourceName
                    Dim typeName As String = parameterResult.freeBasicType
                    Dim typeEnd As Long = i - 1
                    If typeEnd >= start AndAlso tokens(typeEnd) = parameterName Then typeEnd -= 1
                    If typeMappingKind = C2FB_TYPE_MAPPING_BODY AndAlso InStr(typeName, " Ptr") = 0 AndAlso _
                       IsCBodyCallbackTypeInContext(translation, typeName) = 0 AndAlso _
                       C2fbTypeRecognitionStatusInContext( _
                           translation, catalog, tokens(), start, typeEnd) <> _
                       C2FB_TYPE_RESOLUTION_RESOLVED Then Exit Sub
                    If parameterCount > 0 Then parameters &= ", "
                    parameters &= "ByVal " & parameterResult.freeBasicDeclaration
                    parameterTypes &= typeName & "|"
                    parameterCount += 1
                End If
            End If
            start = i + 1
            If atEnd <> 0 Then
                foundEnd = -1
                parameterClose = i
                If i <> callbackSignatureLastToken Then Exit Sub
                Exit For
            End If
        End If
    Next
    If foundEnd = 0 Then Exit Sub
    Dim callingConvention As String = CBodyCallbackCallConv( _
        tokens(), firstToken, lastToken, opening, pointerClose, parameterClose)
    If callingConvention = "Invalid" Then Exit Sub
    If isVariadic <> 0 AndAlso callingConvention <> "CDecl" Then Exit Sub
    Dim declaration As String
    If isVariadic <> 0 Then parameters &= ", ..."
    If returnType = "void" Then
        declaration = "Sub " & callingConvention & "(" & parameters & ")"
    Else
        declaration = "Function " & callingConvention & "(" & parameters & ") As " & returnType
    End If
    Dim callbackIndex As Long = CBodyCallbackIndexInContext( _
        translation, declaration)
    If callbackIndex < 0 Then
        If translation.body.callbackCount >= _
           MAX_C2FB_BODY_CALLBACK_TYPES Then _
            ReportError("callbacks exceed the configured signature limit")
        If translation.body.callbackCount > UBound(translation.body.callbacks) Then _
            ReDim Preserve translation.body.callbacks(0 To UBound(translation.body.callbacks) * 2 + 1)
        callbackIndex = translation.body.callbackCount
        With translation.body.callbacks(translation.body.callbackCount)
            .fbType = NextCBodyGeneratedCallbackTypeName(translation, catalog)
            .declaration = declaration
            .returnType = returnType
            .parameterTypes = parameterTypes
            .parameterCount = parameterCount
            .isVariadic = isVariadic
        End With
        translation.body.callbackCount += 1
    End If
    result.freeBasicType = translation.body.callbacks(callbackIndex).fbType
    result.status = C2FB_CALLBACK_TYPE_CONVERTED
End Sub

/' end of c2fb_callbacks.bi '/
