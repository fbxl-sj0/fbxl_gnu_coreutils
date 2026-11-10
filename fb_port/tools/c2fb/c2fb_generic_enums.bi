/'
    Project: C2FB generic C enum support

    File: c2fb_generic_enums.bi

    Purpose:

        Retain supported C enum values for generic body conversion and lower
        enum constants into generic FreeBASIC bindings.

    Responsibilities:

        - Assign stable FreeBASIC names to enum members.
        - Translate explicit values and implicit increments.
        - Retain known numeric values for enum-based fixed array bounds.
        - Resolve array-count enum values after file-scope extents are known.
        - Index known integer values for generic C body expressions.
        - Index anonymous enum members declared inside record fields.
        - Emit enum constants through the common output backend.

    This file intentionally does NOT contain:

        - General macro expansion or record layout validation.
        - C preprocessing or SQLite-specific constant policy.
'/

Private Function GenericEnumMemberIndexInContext( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As Long
    If translation.genericC.header.enumMemberIndex.capacity <= 0 Then _
        ResetC2fbStringIndexMap( _
            translation.genericC.header.enumMemberIndex)
    Return C2fbStringIndexMapLookup( _
        translation.genericC.header.enumMemberIndex, sourceName)
End Function

Private Sub AddGenericEnumMemberToIndex( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByVal memberIndex As Long _
)
    If sourceName = "" Then Exit Sub
    If translation.genericC.header.enumMemberIndex.capacity <= 0 Then _
        ResetC2fbStringIndexMap( _
            translation.genericC.header.enumMemberIndex)
    If C2fbStringIndexMapLookup( _
        translation.genericC.header.enumMemberIndex, sourceName) >= 0 Then _
        Exit Sub
    If AddC2fbStringIndexMapEntry( _
        translation.genericC.header.enumMemberIndex, sourceName, memberIndex) = 0 Then _
        ReportError("generic enum member index exceeds the configured limit")
End Sub

Private Function GenericEnumCTypeWord(ByVal sourceName As String) As Long
    Select Case LCase(sourceName)
    Case "auto", "bool", "char", "const", "double", "enum", _
         "extern", "float", "inline", "int", "long", "register", _
         "restrict", "short", "signed", "static", "struct", _
         "union", "unsigned", "void", "volatile", "_bool", _
         "_complex", "_generic", "_imaginary", "_alignof", _
         "alignof", "countof", "offsetof", "sizeof", "typeof", _
         "__alignof__", "__extension__", "__typeof__"
        Return -1
    End Select
    Return 0
End Function

Private Function GenericEnumExpressionRetryStage( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByVal resolutionStage As Long _
) As Long
    If resolutionStage >= 2 Then Return 0
    Dim loweredExpression As String = LCase(sourceExpression)
    If InStr(loweredExpression, "sizeof") <> 0 OrElse _
       InStr(loweredExpression, "offsetof") <> 0 OrElse _
       InStr(loweredExpression, "alignof") <> 0 OrElse _
       InStr(loweredExpression, "countof") <> 0 Then
        If resolutionStage < 2 Then Return 2
        Return 0
    End If
    If InStr(loweredExpression, "_generic") <> 0 AndAlso _
       resolutionStage < 1 Then Return 1

    Dim position As Long = 1
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If quoteByte <> 0 Then
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
            Continue While
        ElseIf currentByte = Asc("'") OrElse _
               currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
            position += 1
            Continue While
        ElseIf currentByte >= Asc("0") AndAlso currentByte <= Asc("9") Then
            position += 1
            While position <= Len(sourceExpression) AndAlso _
                  IsIdentifierPart(Asc(sourceExpression, position)) <> 0
                position += 1
            Wend
            Continue While
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceExpression) AndAlso _
                  IsIdentifierPart(Asc(sourceExpression, position)) <> 0
                position += 1
            Wend
            Dim sourceName As String = Mid( _
                sourceExpression, tokenStart, position - tokenStart)
            Dim enumIndex As Long = _
                GenericEnumMemberIndexInContext(translation, sourceName)
            If enumIndex >= 0 Then
                With translation.genericC.header.enumMembers(enumIndex)
                    If .integerValueKnown = 0 AndAlso _
                       .enumValueRetryStage > 0 AndAlso _
                       .enumValueRetryStage >= resolutionStage Then _
                        Return .enumValueRetryStage
                End With
            ElseIf GenericEnumCTypeWord(sourceName) = 0 AndAlso _
                   resolutionStage < 1 Then
                ' A later enum member or typedef may not be indexed yet.
                Return 1
            End If
            Continue While
        End If
        position += 1
    Wend
    Return 0
End Function

Declare Function EvaluateGenericEnumIntegerValue( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef integerValue As Long _
) As Long
Declare Function ReplaceGenericHeaderAlignofExpressions( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, _
    ByRef normalizedExpression As String _
) As Long
Declare Function ReplaceGenericHeaderOffsetofExpressions( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, _
    ByRef normalizedExpression As String _
) As Long
Declare Function ReplaceGenericHeaderSizeofExpressions( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, _
    ByRef normalizedExpression As String _
) As Long

Private Function GenericEnumIdentifierByte(ByVal characterByte As Long) As Long
    Return CInt((characterByte >= Asc("a") AndAlso characterByte <= Asc("z")) OrElse _
        (characterByte >= Asc("A") AndAlso characterByte <= Asc("Z")) OrElse _
        (characterByte >= Asc("0") AndAlso characterByte <= Asc("9")) OrElse _
        characterByte = Asc("_"))
End Function

Private Function GenericFindAnonymousEnumBody( _
    ByVal sourceText As String, ByRef enumBody As String, _
    ByRef enumStart As Long, ByRef enumEnd As Long, _
    ByVal searchStart As Long = 1 _
) As Long
    enumBody = ""
    enumStart = 0
    enumEnd = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    If searchStart < 1 Then searchStart = 1
    For position As Long = searchStart To Len(sourceText) - Len("enum") + 1
        Dim currentByte As Long = Asc(sourceText, position)
        If quoteByte <> 0 Then
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            Continue For
        End If
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quoteByte = currentByte
            Continue For
        End If
        If position > 1 AndAlso _
           GenericEnumIdentifierByte(Asc(sourceText, position - 1)) <> 0 Then _
            Continue For
        If LCase(Mid(sourceText, position, Len("enum"))) <> "enum" Then Continue For
        Dim afterKeyword As Long = position + Len("enum")
        If afterKeyword <= Len(sourceText) AndAlso _
           GenericEnumIdentifierByte(Asc(sourceText, afterKeyword)) <> 0 Then _
            Continue For
        While afterKeyword <= Len(sourceText) AndAlso _
              IsSpaceByte(Asc(sourceText, afterKeyword)) <> 0
            afterKeyword += 1
        Wend
        If afterKeyword > Len(sourceText) OrElse _
           Mid(sourceText, afterKeyword, 1) <> "{" Then Continue For

        Dim braceDepth As Long = 1
        quoteByte = 0
        escaped = 0
        For scanPosition As Long = afterKeyword + 1 To Len(sourceText)
            currentByte = Asc(sourceText, scanPosition)
            If quoteByte <> 0 Then
                If escaped <> 0 Then
                    escaped = 0
                ElseIf currentByte = Asc(Chr(92)) Then
                    escaped = -1
                ElseIf currentByte = quoteByte Then
                    quoteByte = 0
                End If
                Continue For
            End If
            If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
                quoteByte = currentByte
            ElseIf currentByte = Asc("{") Then
                braceDepth += 1
            ElseIf currentByte = Asc("}") Then
                braceDepth -= 1
                If braceDepth = 0 Then
                    enumBody = Mid(sourceText, afterKeyword + 1, _
                        scanPosition - afterKeyword - 1)
                    enumStart = position
                    enumEnd = scanPosition
                    Return -1
                End If
            End If
        Next
        Return 0
    Next
    Return 0
End Function

Declare Function GenericAnonymousEnumBodyFitsCInt( _
    ByRef translation As C2fbTranslationContext, ByVal enumBody As String _
) As Long

Private Function GenericAnonymousEnumFieldTypeBody( _
    ByRef translation As C2fbTranslationContext, _
    ByVal fieldDeclaration As String, ByRef enumBody As String _
) As Long
    Dim enumStart As Long
    Dim enumEnd As Long
    If GenericFindAnonymousEnumBody( _
        fieldDeclaration, enumBody, enumStart, enumEnd) = 0 Then Return 0
    If GenericAnonymousEnumBodyFitsCInt(translation, enumBody) = 0 Then Return 0
    Return -1
End Function

Private Function GenericAnonymousEnumBodyFitsCInt( _
    ByRef translation As C2fbTranslationContext, ByVal enumBody As String _
) As Long
    Dim enumParts() As String
    Dim enumPartCount As Long
    If SplitSimpleCList( _
        enumBody, enumParts(), enumPartCount, -1, _
        MAX_GENERIC_ENUM_MEMBERS) = 0 Then Return 0
    Dim previousValue As Long = 0
    Dim previousValueKnown As Long = 0
    For partIndex As Long = 0 To enumPartCount - 1
        Dim partText As String = Trim(enumParts(partIndex))
        If partText = "" Then Continue For
        Dim enumTokens() As String
        Dim enumTokenCount As Long
        TokenizeCDeclaration(partText, enumTokens(), enumTokenCount)
        If enumTokenCount = 0 OrElse IsIdentifierToken(enumTokens(0)) = 0 Then _
            Return 0
        Dim integerValue As Long = 0
        Dim equalsPosition As Long = InStr(partText, "=")
        If equalsPosition = 0 Then
            If partIndex = 0 Then
                previousValueKnown = -1
            ElseIf previousValueKnown <> 0 AndAlso _
                   previousValue < MAX_GENERIC_ARRAY_COUNT Then
                integerValue = previousValue + 1
                previousValueKnown = -1
            Else
                Return 0
            End If
        Else
            If EvaluateGenericEnumIntegerValue( _
                translation, Trim(Mid(partText, equalsPosition + 1)), _
                integerValue) = 0 Then Return 0
            previousValueKnown = -1
        End If
        ' This C2FB profile uses the target's default 32-bit C int enum ABI.
        If integerValue < (-2147483647LL - 1LL) OrElse _
           integerValue > 2147483647LL Then Return 0
        previousValue = integerValue
    Next
    Return -1
End Function

Private Sub IndexGenericAnonymousEnumBody( _
    ByRef translation As C2fbTranslationContext, ByVal enumBody As String _
)
    Dim enumParts() As String
    Dim enumPartCount As Long
    If SplitSimpleCList( _
        enumBody, enumParts(), enumPartCount, -1, _
        MAX_GENERIC_ENUM_MEMBERS) = 0 Then Exit Sub

    Dim previousValue As Long = 0
    Dim previousValueKnown As Long = 0
    Dim memberCount As Long = 0
    For partIndex As Long = 0 To enumPartCount - 1
        Dim partText As String = Trim(enumParts(partIndex))
        If partText = "" Then Continue For
        Dim enumTokens() As String
        Dim enumTokenCount As Long
        TokenizeCDeclaration(partText, enumTokens(), enumTokenCount)
        If enumTokenCount = 0 OrElse IsIdentifierToken(enumTokens(0)) = 0 Then
            previousValueKnown = 0
            memberCount += 1
            Continue For
        End If

        Dim sourceName As String = enumTokens(0)
        Dim equalsPosition As Long = InStr(partText, "=")
        Dim integerValue As Long = 0
        Dim integerValueKnown As Long = 0
        If equalsPosition = 0 Then
            If memberCount = 0 Then
                integerValueKnown = -1
            ElseIf previousValueKnown <> 0 AndAlso _
                   previousValue < MAX_GENERIC_ARRAY_COUNT Then
                integerValue = previousValue + 1
                integerValueKnown = -1
            End If
        ElseIf EvaluateGenericEnumIntegerValue( _
            translation, Trim(Mid(partText, equalsPosition + 1)), _
            integerValue) <> 0 Then
            integerValueKnown = -1
        End If

        Dim duplicateIndex As Long = _
            GenericEnumMemberIndexInContext(translation, sourceName)
        If duplicateIndex >= 0 Then
            If translation.genericC.header.enumMembers( _
                duplicateIndex).integerValueKnown = 0 AndAlso _
               integerValueKnown <> 0 Then
                With translation.genericC.header.enumMembers(duplicateIndex)
                    .integerValue = integerValue
                    .integerValueKnown = -1
                End With
            End If
            previousValue = translation.genericC.header.enumMembers( _
                duplicateIndex).integerValue
            previousValueKnown = translation.genericC.header.enumMembers( _
                duplicateIndex).integerValueKnown
            memberCount += 1
            Continue For
        End If

        If translation.genericC.header.enumMemberCount >= _
           MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
            ReportError("generic body exceeds the configured enum constant limit")
        If translation.genericC.header.enumMemberCount > _
           UBound(translation.genericC.header.enumMembers) Then _
            ReDim Preserve translation.genericC.header.enumMembers( _
                0 To UBound(translation.genericC.header.enumMembers) * 2 + 1)
        With translation.genericC.header.enumMembers( _
            translation.genericC.header.enumMemberCount)
            .sourceName = sourceName
            .freeBasicName = ""
            .enumTypeName = ""
            .enumTagName = ""
            .integerValue = integerValue
            .integerValueKnown = integerValueKnown
            .isEmitted = 0
        End With
        AddGenericEnumMemberToIndex( _
            translation, sourceName, translation.genericC.header.enumMemberCount)
        translation.genericC.header.enumMemberCount += 1
        previousValue = integerValue
        previousValueKnown = integerValueKnown
        memberCount += 1
    Next
End Sub

Declare Function GenericArrayBoundNormalizeType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByVal depth As Long = 0 _
) As String
Private Declare Function GenericArrayBoundTypedefSourceType( _
    ByRef translation As C2fbTranslationContext, ByVal sourceType As String _
) As String

Declare Function GenericHeaderEnumMemberRemoved( _
    ByRef sourceDeclaration As C2fbDeclarationModel, ByVal sourceName As String _
) As Long

Declare Function TranslateGenericEnumExpressionWithBodyParser( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String _
) As Long

Function TranslateGenericEnumExpressionWithBodyParser( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String _
) As Long
    Dim callableNames(0 To 0) As String
    Dim parameterNames(0 To 0) As String
    Dim parameterAliases(0 To 0) As String
    Dim parameterTypes(0 To 0) As String
    Dim hasBooleanOperator As Long
    Dim hasFunctionCall As Long

    ' Enum values must remain integer constant expressions. The body parser
    ' handles C constructs such as _Generic before the header fallback runs.
    Return TranslateSimpleExpression( _
        translation, catalog, sourceExpression, freeBasicExpression, _
        hasBooleanOperator, hasFunctionCall, callableNames(), 0, _
        parameterNames(), parameterAliases(), parameterTypes(), 0, "", -1, -1)
End Function

Private Function GenericEnumMemberFreeBasicReference( _
    ByRef translation As C2fbTranslationContext, ByVal enumIndex As Long, _
    ByRef freeBasicReference As String _
) As Long
    freeBasicReference = ""
    If enumIndex < 0 OrElse _
       enumIndex >= translation.genericC.header.enumMemberCount Then Return 0
    With translation.genericC.header.enumMembers(enumIndex)
        If .isEmitted <> 0 Then
            freeBasicReference = .freeBasicName
            Return CInt(freeBasicReference <> "")
        End If
        If .integerValueKnown = 0 Then Return 0
        freeBasicReference = Trim(Str(.integerValue))
        Return -1
    End With
End Function

Private Function ReplaceGenericEnumNamesWithIntegerValues( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef numericExpression As String _
) As Long
    numericExpression = ""
    Dim scanPosition As Long = 1
    Dim scanQuoteByte As Long = 0
    Dim scanEscaped As Long = 0
    Dim hasIdentifier As Long = 0
    While scanPosition <= Len(sourceExpression)
        Dim scanByte As Long = Asc(sourceExpression, scanPosition)
        If scanQuoteByte <> 0 Then
            If scanEscaped <> 0 Then
                scanEscaped = 0
            ElseIf scanByte = Asc(Chr(92)) Then
                scanEscaped = -1
            ElseIf scanByte = scanQuoteByte Then
                scanQuoteByte = 0
            End If
        ElseIf scanByte = Asc("'") OrElse _
               scanByte = Asc(Chr(34)) Then
            scanQuoteByte = scanByte
        ElseIf IsIdentifierStart(scanByte) <> 0 Then
            hasIdentifier = -1
            Exit While
        End If
        scanPosition += 1
    Wend
    If hasIdentifier = 0 Then
        ' Large expanded constant macros often contain only literals and
        ' operators. Avoid rebuilding every byte when there are no enum names.
        numericExpression = sourceExpression
        Return -1
    End If

    Dim position As Long = 1
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If quoteByte <> 0 Then
            numericExpression &= Chr(currentByte)
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
            Continue While
        ElseIf currentByte = Asc("'") OrElse _
               currentByte = Asc(Chr(34)) Then
            ' Letters inside C character constants are values, not enum names.
            quoteByte = currentByte
            numericExpression &= Chr(currentByte)
            position += 1
            Continue While
        End If

        If currentByte >= Asc("0") AndAlso currentByte <= Asc("9") Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceExpression) AndAlso _
                  IsIdentifierPart(Asc(sourceExpression, position)) <> 0
                position += 1
            Wend
            numericExpression &= Mid( _
                sourceExpression, tokenStart, position - tokenStart)
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceExpression) AndAlso _
                  IsIdentifierPart(Asc(sourceExpression, position)) <> 0
                position += 1
            Wend
            Dim sourceName As String = Mid( _
                sourceExpression, tokenStart, position - tokenStart)
            Dim enumIndex As Long = _
                GenericEnumMemberIndexInContext(translation, sourceName)
            If enumIndex < 0 OrElse _
               translation.genericC.header.enumMembers(enumIndex).integerValueKnown = 0 Then _
                Return 0
            numericExpression &= Trim(Str( _
                translation.genericC.header.enumMembers(enumIndex).integerValue))
        Else
            numericExpression &= Chr(currentByte)
            position += 1
        End If
    Wend
    Return -1
End Function

Private Function GenericArrayBoundTypeSize( _
    ByVal sourceType As String, ByRef byteSize As Long _
) As Long
    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(sourceType, typeTokens(), typeTokenCount)
    If typeTokenCount <= 0 Then Return 0
    Dim typeName As String
    Dim pointerDepth As Long = 0
    For tokenIndex As Long = 0 To typeTokenCount - 1
        If IsQualifierToken(typeTokens(tokenIndex)) <> 0 Then Continue For
        If typeTokens(tokenIndex) = "*" Then
            pointerDepth += 1
            Continue For
        End If
        If typeName <> "" Then typeName &= " "
        typeName &= LCase(typeTokens(tokenIndex))
    Next
    If pointerDepth > 0 Then
        byteSize = CLng(SizeOf(Any Ptr))
        For pointerIndex As Long = 1 To pointerDepth - 1
            byteSize *= CLng(SizeOf(Any Ptr))
        Next
        Return -1
    End If
    Select Case typeName
    Case "char", "signed char", "unsigned char", "_bool": byteSize = 1
    Case "short", "short int", "signed short", "signed short int", _
         "unsigned short", "unsigned short int": byteSize = 2
    Case "int_least16_t", "uint_least16_t", _
         "c2fb_int_least16_t", "c2fb_uint_least16_t": byteSize = 2
    Case "int", "signed", "signed int", "unsigned", "unsigned int": _
        byteSize = CLng(SizeOf(Long))
    Case "int_least32_t", "uint_least32_t", _
         "c2fb_int_least32_t", "c2fb_uint_least32_t": _
        byteSize = CLng(SizeOf(Long))
    Case "long", "long int", "signed long", "signed long int", _
         "unsigned long", "unsigned long int":
#if defined(__FB_64BIT__) AndAlso Not defined(__FB_WIN32__)
        byteSize = CLng(SizeOf(LongInt))
#else
        byteSize = CLng(SizeOf(Long))
#endif
    Case "long long", "long long int", "signed long long", _
         "signed long long int", "unsigned long long", _
         "unsigned long long int": byteSize = CLng(SizeOf(LongInt))
    Case "int_least64_t", "uint_least64_t", _
         "c2fb_int_least64_t", "c2fb_uint_least64_t": _
        byteSize = CLng(SizeOf(LongInt))
    Case "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", _
         "c2fb_size_t": _
        byteSize = CLng(SizeOf(Any Ptr))
    Case "float": byteSize = CLng(SizeOf(Single))
    Case "double": byteSize = CLng(SizeOf(Double))
    Case "_float16", "__bf16", "c2fb_float16", "c2fb_bfloat16": _
        byteSize = 2
    Case Else
        Return 0
    End Select
    Return -1
End Function

Private Function GenericArrayBoundRecordTypeSizeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByRef byteSize As Long, _
    ByVal depth As Long = 0 _
) As Long
    If depth >= 32 Then Return 0
    ' Reuse a prepared header layout for record typedefs and tagged records.
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(Trim(sourceType), tokens(), tokenCount)
    If tokenCount <= 0 Then Return 0

    Dim sourceName As String
    Dim isTag As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case LCase(tokens(tokenIndex))
        Case "const", "volatile", "restrict", "__const", "__volatile", _
             "__restrict", "__restrict__"
            Continue For
        Case "struct", "union"
            If isTag <> 0 OrElse sourceName <> "" Then Return 0
            isTag = -1
        Case "*", "[", "]"
            Return 0
        Case Else
            If IsIdentifierToken(tokens(tokenIndex)) = 0 Then Return 0
            If sourceName <> "" Then sourceName &= " "
            sourceName &= tokens(tokenIndex)
        End Select
    Next
    If sourceName = "" Then Return 0

    Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, sourceName, isTag)
    Dim freeBasicType As String
    If aliasIndex >= 0 Then
        freeBasicType = translation.genericC.header.headerTypeAliases( _
            aliasIndex).freeBasicName
    End If
    If freeBasicType = "" AndAlso isTag <> 0 Then
        freeBasicType = GenericHeaderTagAliasNameInHeader( _
            translation.genericC.header, sourceName)
    End If
    If freeBasicType = "" Then
        freeBasicType = GenericTypeOverrideInPolicy( _
            translation.genericC.policy, sourceName)
    End If
    If freeBasicType = "" Then freeBasicType = sourceName

    byteSize = GenericHeaderSimpleRecordSizeInBytes( _
        translation, freeBasicType)
    If byteSize > 0 Then Return -1

    Dim typedefSourceType As String = GenericArrayBoundTypedefSourceType( _
        translation, sourceName)
    If typedefSourceType <> "" AndAlso typedefSourceType <> sourceName Then
        Return GenericArrayBoundRecordTypeSizeInContext( _
            translation, typedefSourceType, byteSize, depth + 1)
    End If
    Return 0
End Function

Private Function GenericArrayBoundTypeSizeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByRef byteSize As Long _
) As Long
    Dim originalSourceType As String = Trim(sourceType)
    sourceType = GenericArrayBoundNormalizeType(translation, sourceType)
    If sourceType = "" Then
        Return GenericArrayBoundRecordTypeSizeInContext( _
            translation, originalSourceType, byteSize)
    End If
    If sourceType = "long double" Then
        byteSize = GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_LONG_DOUBLE__")
        If byteSize <= 0 Then
            ' Generic-body translation can run without a generic-header macro
            ' table. In that case, use the ABI storage selected by this FBC
            ' target, matching crt/longdouble.bi.
#if defined( __FB_64BIT__ ) and not (defined( __FB_ARM__ ) and (defined( __FB_DARWIN__ ) or defined( __FB_WIN32__ )))
            byteSize = 16
#elseif defined( __FB_ARM__ ) or defined( __FB_MIPS32__ )
            byteSize = 8
#else
            byteSize = 12
#endif
        End If
        Return CInt(byteSize > 0) * -1
    End If
    If GenericArrayBoundTypeSize(sourceType, byteSize) <> 0 Then Return -1

    If GenericArrayBoundRecordTypeSizeInContext( _
        translation, originalSourceType, byteSize) <> 0 Then Return -1
    If sourceType <> originalSourceType AndAlso _
       GenericArrayBoundRecordTypeSizeInContext( _
           translation, sourceType, byteSize) <> 0 Then Return -1
    Return 0
End Function

Private Function GenericEnumCastMayHaveIntegerType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByVal openPosition As Long _
) As Long
    Dim typePosition As Long = openPosition + 1
    SkipCSpaces(sourceExpression, typePosition)
    If typePosition > Len(sourceExpression) OrElse _
       IsIdentifierStart(Asc(sourceExpression, typePosition)) = 0 Then Return 0

    Dim tokenStart As Long = typePosition
    typePosition += 1
    While typePosition <= Len(sourceExpression) AndAlso _
          IsIdentifierPart(Asc(sourceExpression, typePosition)) <> 0
        typePosition += 1
    Wend
    Dim firstTypeName As String = Mid( _
        sourceExpression, tokenStart, typePosition - tokenStart)

    ' C casts begin with a type name. Reject ordinary grouping expressions
    ' before scanning ahead for their closing parenthesis; expanded system
    ' macros can contain many nested groups in one enum value.
    Select Case LCase(firstTypeName)
    Case "char", "short", "int", "long", "float", "double", _
         "signed", "unsigned", "_bool", "bool", "void", _
         "const", "volatile", "restrict", "__const", "__volatile", _
         "__restrict", "struct", "union", "enum", "_atomic", _
         "typeof", "__typeof__", "__attribute__", "__int128", _
         "__uint128_t", "size_t", "ssize_t", "ptrdiff_t", _
         "intptr_t", "uintptr_t", "wchar_t"
        Return -1
    End Select

    If GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, firstTypeName, 0) >= 0 OrElse _
       GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, firstTypeName, -1) >= 0 Then Return -1
    Return 0
End Function

Private Function GenericArrayBoundObjectSizeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef byteSize As Long _
) As Long
    sourceExpression = Trim(sourceExpression)
    Dim elementAccess As Long = 0
    Dim bracketPosition As Long = InStr(sourceExpression, "[")
    Dim objectName As String = sourceExpression
    If bracketPosition > 0 Then
        Dim bracketEnd As Long = bracketPosition
        If ScanSimpleExpressionGroup( _
            sourceExpression, bracketEnd, Asc("["), Asc("]")) = 0 Then _
            Return 0
        If Trim(Mid(sourceExpression, bracketPosition + 1, _
                    bracketEnd - bracketPosition - 2)) <> "0" OrElse _
           Trim(Mid(sourceExpression, bracketEnd + 1)) <> "" Then Return 0
        objectName = Trim(Left(sourceExpression, bracketPosition - 1))
        elementAccess = -1
    End If
    If IsIdentifierToken(objectName) = 0 Then Return 0
    Dim objectIndex As Long = -1
    For index As Long = 0 To translation.body.externalObjectCount - 1
        With translation.body.externalObjects(index)
            If .sourceName <> objectName OrElse .isAmbiguous <> 0 Then Continue For
            If objectIndex >= 0 Then Return 0
            objectIndex = index
        End With
    Next
    If objectIndex < 0 Then Return 0
    With translation.body.externalObjects(objectIndex)
        If .isArray = 0 OrElse .arrayRank <> 1 OrElse _
           .arrayCount < 1 OrElse .freeBasicType = "" Then Return 0
        Dim elementSize As Long
        If GenericArrayBoundTypeSizeInContext( _
            translation, .freeBasicType, elementSize) = 0 OrElse _
           elementSize < 1 Then
            Return 0
        End If
        If elementAccess <> 0 Then
            byteSize = elementSize
        Else
            If .arrayCount > (&H7FFFFFFF \ elementSize) Then Return 0
            byteSize = .arrayCount * elementSize
        End If
    End With
    Return -1
End Function

Private Function GenericArrayBoundSizeofIsZeroMultiplied( _
    ByVal sourceExpression As String, ByVal sizeofPosition As Long _
) As Long
    Dim position As Long = sizeofPosition - 1
    While position > 0 AndAlso _
          IsSpaceByte(Asc(sourceExpression, position)) <> 0
        position -= 1
    Wend
    If position <= 0 OrElse Asc(sourceExpression, position) <> Asc("*") Then _
        Return 0
    position -= 1
    While position > 0 AndAlso _
          IsSpaceByte(Asc(sourceExpression, position)) <> 0
        position -= 1
    Wend
    Dim tokenEnd As Long = position
    While position > 0 AndAlso IsIdentifierPart( _
        Asc(sourceExpression, position)) <> 0
        position -= 1
    Wend
    If Trim(Mid(sourceExpression, position + 1, tokenEnd - position)) <> "0" Then _
        Return 0
    If position > 0 AndAlso IsIdentifierPart( _
        Asc(sourceExpression, position)) <> 0 Then Return 0
    Return -1
End Function

Private Function GenericArrayBoundStringSize( _
    ByVal sourceText As String, ByRef position As Long, _
    ByRef byteSize As Long _
) As Long
    Dim characterCount As Long = 0
    Dim literalCount As Long = 0
    Do
        SkipCSpaces(sourceText, position)
        If position > Len(sourceText) OrElse _
           Asc(sourceText, position) <> Asc(Chr(34)) Then Exit Do
        position += 1
        literalCount += 1
        Dim closed As Long = 0
        While position <= Len(sourceText)
            Dim currentByte As Long = Asc(sourceText, position)
            If currentByte = Asc(Chr(34)) Then
                position += 1
                closed = -1
                Exit While
            ElseIf currentByte = Asc(Chr(92)) Then
                position += 1
                If position > Len(sourceText) Then Return 0
                currentByte = Asc(sourceText, position)
                If currentByte = Asc("x") OrElse currentByte = Asc("X") Then
                    position += 1
                    Dim digitCount As Long = 0
                    While position <= Len(sourceText) AndAlso _
                          IsHexDigit(Asc(sourceText, position)) <> 0
                        position += 1
                        digitCount += 1
                    Wend
                    If digitCount = 0 Then Return 0
                ElseIf currentByte >= Asc("0") AndAlso _
                       currentByte <= Asc("7") Then
                    Dim digitCount As Long = 0
                    While position <= Len(sourceText) AndAlso _
                          Asc(sourceText, position) >= Asc("0") AndAlso _
                          Asc(sourceText, position) <= Asc("7") AndAlso _
                          digitCount < 3
                        position += 1
                        digitCount += 1
                    Wend
                ElseIf currentByte = Asc("u") OrElse _
                       currentByte = Asc("U") Then
                    ' Universal characters depend on the execution encoding.
                    Return 0
                Else
                    position += 1
                End If
                characterCount += 1
            Else
                If currentByte = 10 OrElse currentByte = 13 Then Return 0
                position += 1
                characterCount += 1
            End If
        Wend
        If closed = 0 Then Return 0
    Loop
    If literalCount = 0 Then Return 0
    byteSize = characterCount + 1
    Return -1
End Function

Private Function NormalizeGenericArrayBoundSizeof( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef normalizedExpression As String _
) As Long
    normalizedExpression = ""
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        If Mid(sourceExpression, position, Len("sizeof")) = "sizeof" AndAlso _
           (position = 1 OrElse _
            IsIdentifierPart(Asc(sourceExpression, position - 1)) = 0) Then
            Dim operandPosition As Long = position + Len("sizeof")
            If operandPosition <= Len(sourceExpression) AndAlso _
               IsIdentifierPart(Asc(sourceExpression, operandPosition)) <> 0 Then
                normalizedExpression &= Mid(sourceExpression, position, 1)
                position += 1
                Continue While
            End If
            SkipCSpaces(sourceExpression, operandPosition)
            Dim byteSize As Long
            If operandPosition <= Len(sourceExpression) AndAlso _
               Asc(sourceExpression, operandPosition) = Asc(Chr(34)) Then
                If GenericArrayBoundStringSize( _
                    sourceExpression, operandPosition, byteSize) = 0 Then Return 0
            ElseIf operandPosition <= Len(sourceExpression) AndAlso _
                   Asc(sourceExpression, operandPosition) = Asc("(") Then
                Dim groupEnd As Long = operandPosition
                If ScanSimpleExpressionGroup( _
                    sourceExpression, groupEnd, Asc("("), Asc(")")) = 0 Then
                    Return 0
                End If
                Dim typeName As String = Trim(Mid( _
                    sourceExpression, operandPosition + 1, _
                    groupEnd - operandPosition - 2))
                If GenericArrayBoundSizeofIsZeroMultiplied( _
                    sourceExpression, position) <> 0 Then
                    ' The C compiler has already validated countof's zeroed
                    ' array-check term. Its size does not affect the value.
                    byteSize = 1
                    operandPosition = groupEnd
                Else
                    Dim arrayOperand As String = typeName
                    Dim afterGroup As Long = groupEnd
                    SkipCSpaces(sourceExpression, afterGroup)
                    If afterGroup <= Len(sourceExpression) AndAlso _
                       Asc(sourceExpression, afterGroup) = Asc("[") Then
                        Dim bracketEnd As Long = afterGroup
                        If ScanSimpleExpressionGroup( _
                            sourceExpression, bracketEnd, _
                            Asc("["), Asc("]")) = 0 OrElse _
                           Trim(Mid(sourceExpression, afterGroup + 1, _
                               bracketEnd - afterGroup - 2)) <> "0" Then Return 0
                        arrayOperand &= "[0]"
                        afterGroup = bracketEnd
                    End If
                    If GenericArrayBoundTypeSizeInContext( _
                        translation, typeName, byteSize) = 0 AndAlso _
                       GenericArrayBoundObjectSizeInContext( _
                        translation, arrayOperand, byteSize) = 0 Then
                        Return 0
                    End If
                    operandPosition = afterGroup
                End If
            Else
                Return 0
            End If
            normalizedExpression &= Trim(Str(byteSize))
            position = operandPosition
        Else
            normalizedExpression &= Mid(sourceExpression, position, 1)
            position += 1
        End If
    Wend
    Return -1
End Function

Private Function GenericArrayBoundTypedefSourceType( _
    ByRef translation As C2fbTranslationContext, ByVal sourceType As String _
) As String
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            Dim declarationTokens() As String
            Dim declarationTokenCount As Long = 0
            If .isTypedef <> 0 AndAlso .sourceName = sourceType AndAlso _
               .tokenCount >= 3 Then
                declarationTokenCount = .tokenCount
                ReDim declarationTokens(0 To declarationTokenCount - 1)
                For tokenIndex As Long = 0 To declarationTokenCount - 1
                    declarationTokens(tokenIndex) = .tokens(tokenIndex)
                Next
            Else
                ' The generic source-unit body scanner retains raw typedef
                ' statements without classifying their declarations. Read the
                ' simple alias form here so sizeof can still use its C type.
                TokenizeCDeclaration( _
                    .text, declarationTokens(), declarationTokenCount)
                If declarationTokenCount < 3 OrElse _
                   LCase(declarationTokens(0)) <> "typedef" Then Continue For
            End If
            Dim aliasPosition As Long = -1
            For tokenIndex As Long = 1 To declarationTokenCount - 1
                If LCase(declarationTokens(tokenIndex)) = LCase(sourceType) Then _
                    aliasPosition = tokenIndex
            Next
            If aliasPosition <= 1 Then Continue For
            Dim sourceTypeText As String
            For tokenIndex As Long = 1 To aliasPosition - 1
                If sourceTypeText <> "" Then sourceTypeText &= " "
                sourceTypeText &= declarationTokens(tokenIndex)
            Next
            Return sourceTypeText
        End With
    Next
    Return ""
End Function

Private Function GenericArrayBoundPrimitiveTypeName( _
    ByVal sourceType As String _
) As String
    Select Case sourceType
    Case "char", "signed char", "unsigned char", "_bool", _
         "float", "double", "long double", "_float16", "__bf16"
        Return sourceType
    Case "short", "short int", "signed short", "signed short int"
        Return "short"
    Case "unsigned short", "unsigned short int"
        Return "unsigned short"
    Case "int", "signed", "signed int"
        Return "int"
    Case "unsigned", "unsigned int"
        Return "unsigned int"
    Case "long", "long int", "signed long", "signed long int"
        Return "long"
    Case "unsigned long", "unsigned long int"
        Return "unsigned long"
    Case "long long", "long long int", "signed long long", _
         "signed long long int"
        Return "long long"
    Case "unsigned long long", "unsigned long long int"
        Return "unsigned long long"
    End Select
    Return ""
End Function

Private Function GenericArrayBoundNormalizeType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByVal depth As Long = 0 _
) As String
    ' Header typedefs can reach a C primitive through several ABI aliases.
    ' Keep the lookup bounded before evaluating a _Generic association.
    If depth >= 32 Then Return ""
    sourceType = LCase(Trim(sourceType))
    If sourceType = "" Then Return ""
    ' C keywords remain primitive types even if an included binding uses the
    ' same spelling for a FreeBASIC alias.
    Dim primitiveTypeName As String = _
        GenericArrayBoundPrimitiveTypeName(sourceType)
    If primitiveTypeName <> "" Then Return primitiveTypeName
    ' Body aliases retain FreeBASIC storage names, so resolve those names back
    ' to the C integer rank before comparing them with association types.
    For aliasIndex As Long = 0 To translation.body.aliasCount - 1
        With translation.body.aliases(aliasIndex)
            If .name <> sourceType Then Continue For
            If .ambiguous <> 0 OrElse .baseType = "" OrElse _
               .baseType = sourceType Then Return ""
            Return GenericArrayBoundNormalizeType( _
                translation, .baseType, depth + 1)
        End With
    Next

    Dim typedefSourceType As String = _
        GenericArrayBoundTypedefSourceType(translation, sourceType)
    If typedefSourceType <> "" AndAlso typedefSourceType <> sourceType Then
        Return GenericArrayBoundNormalizeType( _
            translation, typedefSourceType, depth + 1)
    End If

    ' Header typedef aliases may be known before body aliases are indexed.
    ' Follow their generated type layers back to the C primitive rank.
    For aliasIndex As Long = 0 To _
        translation.genericC.header.headerTypeAliasCount - 1
        With translation.genericC.header.headerTypeAliases(aliasIndex)
            If LCase(.sourceName) <> sourceType AndAlso _
               LCase(.freeBasicName) <> sourceType Then Continue For
            Dim aliasBaseType As String = .baseType
            If aliasBaseType = "" Then aliasBaseType = .freeBasicName
            If LCase(aliasBaseType) = sourceType Then Return ""
            Return GenericArrayBoundNormalizeType( _
                translation, aliasBaseType, depth + 1)
        End With
    Next

    Select Case sourceType
    ' These aliases name the standard C integer ranks in generated modules.
    Case "c2fb_c_int", "c2fb_c_uint"
        Return IIf(sourceType = "c2fb_c_int", "int", "unsigned int")
    Case "c2fb_c_long", "clong"
        Return "long"
    Case "c2fb_c_ulong", "culong"
        Return "unsigned long"
    End Select

    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceType, tokens(), tokenCount)
    If tokenCount <= 0 Then Return sourceType
    Dim hasOtherIntegerTypeToken As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case tokens(tokenIndex)
        Case "const", "volatile", "restrict", "__const", "__volatile", _
             "__restrict", "signed", "*", "[", "]"
            Continue For
        Case "int"
            Continue For
        Case Else
            If IsIdentifierToken(tokens(tokenIndex)) <> 0 Then _
                hasOtherIntegerTypeToken = -1
        End Select
    Next

    Dim normalizedType As String
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case tokens(tokenIndex)
        Case "const", "volatile", "restrict", "__const", "__volatile", _
             "__restrict", "signed"
            Continue For
        Case "int"
            If hasOtherIntegerTypeToken <> 0 Then Continue For
        End Select
        If normalizedType <> "" Then normalizedType &= " "
        normalizedType &= tokens(tokenIndex)
    Next
    Return normalizedType
End Function

Private Function GenericArrayBoundTypeSelectionKey( _
    ByRef translation As C2fbTranslationContext, ByVal sourceType As String _
) As String
    Return GenericArrayBoundNormalizeType(translation, sourceType)
End Function

Private Function GenericArrayBoundTypeFromControl( _
    ByRef translation As C2fbTranslationContext, _
    ByVal controlExpression As String, ByRef controlType As String _
) As Long
    controlType = ""
    Dim typeOperator As Long = InStr(controlExpression, "__typeof__")
    If typeOperator = 0 Then Return 0
    Dim groupStart As Long = typeOperator + Len("__typeof__")
    SkipCSpaces(controlExpression, groupStart)
    If groupStart > Len(controlExpression) OrElse _
       Asc(controlExpression, groupStart) <> Asc("(") Then Return 0
    Dim groupEnd As Long = groupStart
    If ScanSimpleExpressionGroup( _
        controlExpression, groupEnd, Asc("("), Asc(")")) = 0 Then Return 0
    controlType = GenericArrayBoundTypeSelectionKey(translation, Trim(Mid( _
        controlExpression, groupStart + 1, groupEnd - groupStart - 2)))
    Return CInt(controlType <> "")
End Function

Private Function GenericArrayBoundAssociationColon( _
    ByVal association As String _
) As Long
    Dim parenthesisDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    For position As Long = 1 To Len(association)
        Dim currentByte As Long = Asc(association, position)
        If quoteByte <> 0 Then
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            Continue For
        End If
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quoteByte = currentByte
        ElseIf currentByte = Asc("(") Then
            parenthesisDepth += 1
        ElseIf currentByte = Asc(")") Then
            parenthesisDepth -= 1
        ElseIf currentByte = Asc("[") Then
            bracketDepth += 1
        ElseIf currentByte = Asc("]") Then
            bracketDepth -= 1
        ElseIf currentByte = Asc("{") Then
            braceDepth += 1
        ElseIf currentByte = Asc("}") Then
            braceDepth -= 1
        ElseIf currentByte = Asc(":") AndAlso parenthesisDepth = 0 AndAlso _
               bracketDepth = 0 AndAlso braceDepth = 0 Then
            Return position
        End If
    Next
    Return 0
End Function

Private Function NormalizeGenericArrayBoundSelections( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef normalizedExpression As String _
) As Long
    normalizedExpression = sourceExpression
    For selectionIndex As Long = 0 To 15
        Dim selectionPosition As Long = InStr(normalizedExpression, "_Generic")
        If selectionPosition = 0 Then Return -1
        Dim groupStart As Long = selectionPosition + Len("_Generic")
        SkipCSpaces(normalizedExpression, groupStart)
        If groupStart > Len(normalizedExpression) OrElse _
           Asc(normalizedExpression, groupStart) <> Asc("(") Then Return 0
        Dim groupEnd As Long = groupStart
        If ScanSimpleExpressionGroup( _
            normalizedExpression, groupEnd, Asc("("), Asc(")")) = 0 Then Return 0
        Dim selectionText As String = Trim(Mid( _
            normalizedExpression, groupStart + 1, groupEnd - groupStart - 2))
        Dim parts() As String
        Dim partCount As Long
        If SplitSimpleCList(selectionText, parts(), partCount) = 0 OrElse _
           partCount < 2 Then Return 0
        Dim controlType As String
        If GenericArrayBoundTypeFromControl( _
            translation, parts(0), controlType) = 0 Then Return 0
        Dim selectedExpression As String
        Dim defaultExpression As String
        For partIndex As Long = 1 To partCount - 1
            Dim colonPosition As Long = _
                GenericArrayBoundAssociationColon(parts(partIndex))
            If colonPosition <= 0 Then Return 0
            Dim associationType As String = GenericArrayBoundTypeSelectionKey( _
                translation, Trim(Left( _
                    parts(partIndex), colonPosition - 1)))
            Dim associationValue As String = Trim(Mid( _
                parts(partIndex), colonPosition + 1))
            If associationType = controlType Then
                selectedExpression = associationValue
                Exit For
            ElseIf associationType = "default" Then
                defaultExpression = associationValue
            End If
        Next
        If selectedExpression = "" Then selectedExpression = defaultExpression
        If selectedExpression = "" Then Return 0
        Dim replacementExpression As String = selectedExpression
        Dim literalParser As SimpleArrayBoundParser
        literalParser.sourceText = selectedExpression
        literalParser.position = 1
        Dim literalValue As LongInt
        Dim isPrimaryExpression As Long = CInt( _
            IsIdentifierToken(selectedExpression) <> 0)
        If ReadSimpleArrayBoundLiteral( _
            literalParser, literalValue) <> 0 Then
            SkipCSpaces(literalParser.sourceText, literalParser.position)
            If literalParser.position > Len(literalParser.sourceText) Then _
                isPrimaryExpression = -1
        End If
        If isPrimaryExpression = 0 Then _
            replacementExpression = "(" & selectedExpression & ")"
        normalizedExpression = Left(normalizedExpression, selectionPosition - 1) & _
            replacementExpression & Mid(normalizedExpression, groupEnd)
    Next
    If InStr(normalizedExpression, "_Generic") <> 0 Then Return 0
    Return -1
End Function

Private Function NormalizeGenericEnumIntegerCasts( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef normalizedExpression As String _
) As Long
    normalizedExpression = ""
    Dim scanPosition As Long = 1
    Dim scanQuoteByte As Long = 0
    Dim scanEscaped As Long = 0
    Dim mayContainCast As Long = 0
    While scanPosition <= Len(sourceExpression)
        Dim scanByte As Long = Asc(sourceExpression, scanPosition)
        If scanQuoteByte <> 0 Then
            If scanEscaped <> 0 Then
                scanEscaped = 0
            ElseIf scanByte = Asc(Chr(92)) Then
                scanEscaped = -1
            ElseIf scanByte = scanQuoteByte Then
                scanQuoteByte = 0
            End If
        ElseIf scanByte = Asc("'") OrElse _
               scanByte = Asc(Chr(34)) Then
            scanQuoteByte = scanByte
        ElseIf scanByte = Asc("(") AndAlso _
               GenericEnumCastMayHaveIntegerType( _
                   translation, sourceExpression, scanPosition) <> 0 Then
            mayContainCast = -1
            Exit While
        End If
        scanPosition += 1
    Wend
    If mayContainCast = 0 Then
        normalizedExpression = sourceExpression
        Return -1
    End If

    Dim position As Long = 1
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If quoteByte <> 0 Then
            normalizedExpression &= Chr(currentByte)
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
            Continue While
        ElseIf currentByte = Asc("'") OrElse _
               currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
            normalizedExpression &= Chr(currentByte)
            position += 1
            Continue While
        End If

        If currentByte = Asc("(") AndAlso _
           GenericEnumCastMayHaveIntegerType( _
               translation, sourceExpression, position) <> 0 Then
            Dim castEnd As Long = position
            If ScanSimpleExpressionGroup( _
                sourceExpression, castEnd, Asc("("), Asc(")")) <> 0 Then
                Dim castType As String = Trim(Mid( _
                    sourceExpression, position + 1, _
                    castEnd - position - 2))
                Dim pointerSizedIntegerCast As Long = 0
                Select Case LCase(castType)
                Case "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t"
                    pointerSizedIntegerCast = -1
                End Select
                Dim castTypeSize As Long
                If pointerSizedIntegerCast <> 0 OrElse _
                   GenericArrayBoundTypeSizeInContext( _
                       translation, castType, castTypeSize) <> 0 Then
                    Dim operandStart As Long = castEnd
                    SkipCSpaces(sourceExpression, operandStart)
                    If operandStart <= Len(sourceExpression) AndAlso _
                       Asc(sourceExpression, operandStart) = Asc("(") Then
                        Dim operandEnd As Long = operandStart
                        If ScanSimpleExpressionGroup( _
                            sourceExpression, operandEnd, _
                            Asc("("), Asc(")")) <> 0 Then
                            Dim operandText As String = Mid( _
                                sourceExpression, operandStart + 1, _
                                operandEnd - operandStart - 2)
                            Dim operandParser As SimpleArrayBoundParser
                            operandParser.sourceText = operandText
                            operandParser.position = 1
                            Dim operandValue As LongInt
                            If ReadSimpleArrayBoundConditional( _
                                operandParser, operandValue, 0) <> 0 Then
                                SkipCSpaces( _
                                    operandParser.sourceText, operandParser.position)
                                If operandParser.position > Len(operandParser.sourceText) AndAlso _
                                   operandValue >= 0 AndAlso _
                                   operandValue <= MAX_GENERIC_ARRAY_BOUND_VALUE Then
                                    normalizedExpression &= Mid( _
                                        sourceExpression, operandStart, _
                                        operandEnd - operandStart)
                                    position = operandEnd
                                    Continue While
                                End If
                            End If
                        End If
                    End If
                End If
            End If
        End If

        normalizedExpression &= Chr(currentByte)
        position += 1
    Wend
    Return CInt(normalizedExpression <> "")
End Function

Private Function EvaluateGenericEnumIntegerValue( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef integerValue As Long _
) As Long
    Dim normalizedExpression As String = sourceExpression
    If InStr(LCase(normalizedExpression), "alignof") <> 0 Then
        Dim alignofExpression As String
        If ReplaceGenericHeaderAlignofExpressions( _
            translation, normalizedExpression, alignofExpression) = 0 Then Return 0
        normalizedExpression = alignofExpression
    End If
    If InStr(LCase(normalizedExpression), "offsetof") <> 0 Then
        Dim offsetofExpression As String
        If ReplaceGenericHeaderOffsetofExpressions( _
            translation, normalizedExpression, offsetofExpression) = 0 Then Return 0
        normalizedExpression = offsetofExpression
    End If
    If InStr(normalizedExpression, "sizeof") <> 0 Then
        Dim sizeofExpression As String
        If ReplaceGenericHeaderSizeofExpressions( _
            translation, normalizedExpression, sizeofExpression) <> 0 AndAlso _
           InStr(LCase(sizeofExpression), "sizeof") = 0 Then
            normalizedExpression = sizeofExpression
        Else
            If NormalizeGenericArrayBoundSizeof( _
                translation, normalizedExpression, sizeofExpression) = 0 Then _
                Return 0
            normalizedExpression = sizeofExpression
        End If
    End If
    If InStr(normalizedExpression, "_Generic") <> 0 Then
        Dim genericExpression As String
        If NormalizeGenericArrayBoundSelections( _
            translation, normalizedExpression, genericExpression) = 0 Then Return 0
        normalizedExpression = genericExpression
    End If

    Dim castExpression As String
    If NormalizeGenericEnumIntegerCasts( _
        translation, normalizedExpression, castExpression) = 0 Then Return 0
    normalizedExpression = castExpression

    Dim numericExpression As String
    If ReplaceGenericEnumNamesWithIntegerValues( _
        translation, normalizedExpression, numericExpression) = 0 Then Return 0
    Dim parser As SimpleArrayBoundParser
    parser.sourceText = numericExpression
    parser.position = 1
    Dim value As LongInt
    ' C enumerator values use the same conditional-expression grammar as array
    ' bounds, including shifts, bitwise operators, and the ?: operator.
    If ReadSimpleArrayBoundConditional(parser, value, 0) = 0 Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position <= Len(parser.sourceText) OrElse _
       value < -MAX_GENERIC_ARRAY_BOUND_VALUE OrElse _
       value > MAX_GENERIC_ARRAY_BOUND_VALUE Then Return 0
    integerValue = CLng(value)
    Return -1
End Function

Private Function EvaluateGenericBodyArrayBound( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef arrayCount As Long, _
    ByVal maximumCount As Long = MAX_SIMPLE_ARRAY_COUNT _
) As Long
    Dim integerValue As Long
    If InStr(sourceExpression, "sizeof") <> 0 Then
        Dim normalizedSizeof As String
        If NormalizeGenericArrayBoundSizeof( _
            translation, sourceExpression, normalizedSizeof) = 0 Then Return 0
        sourceExpression = normalizedSizeof
    End If
    If InStr(sourceExpression, "_Generic") <> 0 Then
        Dim normalizedGeneric As String
        If NormalizeGenericArrayBoundSelections( _
            translation, sourceExpression, normalizedGeneric) = 0 Then Return 0
        sourceExpression = normalizedGeneric
    End If
    If maximumCount < 1 OrElse maximumCount > MAX_GENERIC_ARRAY_COUNT OrElse _
       EvaluateGenericEnumIntegerValue( _
           translation, sourceExpression, integerValue) = 0 OrElse _
       integerValue < 1 OrElse integerValue > maximumCount Then Return 0
    arrayCount = integerValue
    Return -1
End Function

Private Sub IndexGenericBodyEnumConstants( _
    ByRef translation As C2fbTranslationContext, _
    ByVal resetExisting As Long = -1, _
    ByVal forceReindex As Long = 0, _
    ByVal profileTimings As Long = 0, _
    ByVal resolutionStage As Long = 0 _
)
    Dim preservedEnumMembers() As GenericEnumMember
    Dim preservedEnumMemberCount As Long = 0
    Dim preservedEnumMemberIndex As C2fbStringIndexMapModel
    Dim enumDeclarationCount As Long = 0
    Dim skippedResolvedEnumCount As Long = 0
    Dim enumNeedingResolutionCount As Long = 0
    Dim enumValueEvaluationCount As Long = 0
    Dim anonymousEnumBodyCount As Long = 0
    If resetExisting <> 0 AndAlso _
       translation.genericC.header.enumMemberCount > 0 Then
        preservedEnumMemberCount = _
            translation.genericC.header.enumMemberCount
        ReDim preservedEnumMembers(0 To preservedEnumMemberCount - 1)
        ResetC2fbStringIndexMap(preservedEnumMemberIndex)
        For memberIndex As Long = 0 To preservedEnumMemberCount - 1
            preservedEnumMembers(memberIndex) = _
                translation.genericC.header.enumMembers(memberIndex)
            Dim preservedName As String = _
                preservedEnumMembers(memberIndex).sourceName
            If preservedName <> "" AndAlso C2fbStringIndexMapLookup( _
                preservedEnumMemberIndex, preservedName) < 0 Then
                If AddC2fbStringIndexMapEntry( _
                    preservedEnumMemberIndex, preservedName, memberIndex) = 0 Then _
                    ReportError("preserved generic enum member index exceeds the configured limit")
            End If
        Next
    End If
    If resetExisting <> 0 Then
        ReDim translation.genericC.header.enumMembers(0 To 255)
        translation.genericC.header.enumMemberCount = 0
        ResetC2fbStringIndexMap( _
            translation.genericC.header.enumMemberIndex)
    End If

    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               .recordKind <> C2FB_RECORD_ENUM Then Continue For
            ' Enum bounds can depend on types and file-scope extents indexed
            ' later in the body pipeline. Skip complete enums on retry passes.
            If resetExisting = 0 AndAlso forceReindex = 0 AndAlso _
               .enumValuesNeedResolution = 0 Then
                skippedResolvedEnumCount += 1
                Continue For
            End If
            enumDeclarationCount += 1
            Dim enumNeedsResolution As Long = 0
            Dim unresolvedMemberCount As Long = 0
            Dim maximumRetryStage As Long = 0
            Dim unresolvedMemberExamples As String
            Dim enumStartedAt As Double = Timer
            Dim enumSourceIncluded As Long = GenericSourceIncludedInPolicy( _
                translation.genericC.policy, .sourceSpan.startLocation.path)
            Dim enumTypeName As String = .recordAlias
            Dim enumTagName As String = .recordTag
            Dim enumParts() As String
            Dim enumPartCount As Long
            If SplitSimpleCList( _
                .recordBody, enumParts(), enumPartCount, -1, _
                MAX_GENERIC_ENUM_MEMBERS) = 0 Then
                .enumValuesNeedResolution = 0
                Continue For
            End If

            Dim previousValue As Long = 0
            Dim previousValueKnown As Long = 0
            Dim previousValueRetryStage As Long = 0
            Dim memberCount As Long = 0
            For partIndex As Long = 0 To enumPartCount - 1
                Dim partText As String = Trim(enumParts(partIndex))
                If partText = "" Then Continue For
                Dim enumTokens() As String
                Dim enumTokenCount As Long
                TokenizeCDeclaration(partText, enumTokens(), enumTokenCount)
                If enumTokenCount = 0 OrElse _
                   IsIdentifierToken(enumTokens(0)) = 0 Then
                    previousValueKnown = 0
                    previousValueRetryStage = _
                        GenericEnumExpressionRetryStage( _
                            translation, partText, resolutionStage)
                    If previousValueRetryStage > maximumRetryStage Then _
                        maximumRetryStage = previousValueRetryStage
                    If previousValueRetryStage > resolutionStage Then _
                        enumNeedsResolution = -1
                    memberCount += 1
                    Continue For
                End If

                Dim sourceName As String = enumTokens(0)
                Dim duplicateIndex As Long = _
                    GenericEnumMemberIndexInContext(translation, sourceName)
                If duplicateIndex >= 0 Then
                    Dim duplicateRetryStage As Long = _
                        translation.genericC.header.enumMembers( _
                            duplicateIndex).enumValueRetryStage
                    If translation.genericC.header.enumMembers( _
                        duplicateIndex).integerValueKnown = 0 AndAlso _
                       (forceReindex <> 0 OrElse _
                        (duplicateRetryStage > 0 AndAlso _
                         duplicateRetryStage <= resolutionStage)) Then
                        Dim resolvedValue As Long
                        Dim resolvedValueKnown As Long = 0
                        Dim equalsPosition As Long = InStr(partText, "=")
                        If equalsPosition = 0 Then
                            If memberCount = 0 Then
                                resolvedValueKnown = -1
                            ElseIf previousValueKnown <> 0 AndAlso _
                                   previousValue < MAX_GENERIC_ARRAY_COUNT Then
                                resolvedValue = previousValue + 1
                                resolvedValueKnown = -1
                            End If
                        ElseIf EvaluateGenericEnumIntegerValue( _
                            translation, Trim(Mid( _
                                partText, equalsPosition + 1)), resolvedValue) <> 0 Then
                            enumValueEvaluationCount += 1
                            resolvedValueKnown = -1
                        Else
                            enumValueEvaluationCount += 1
                        End If
                        If resolvedValueKnown <> 0 Then
                            With translation.genericC.header.enumMembers( _
                                duplicateIndex)
                                .integerValue = resolvedValue
                                .integerValueKnown = -1
                                .enumValueRetryStage = 0
                            End With
                            duplicateRetryStage = 0
                        ElseIf equalsPosition = 0 Then
                            duplicateRetryStage = previousValueRetryStage
                        Else
                            duplicateRetryStage = GenericEnumExpressionRetryStage( _
                                translation, Trim(Mid( _
                                    partText, equalsPosition + 1)), resolutionStage)
                        End If
                        If duplicateRetryStage > maximumRetryStage Then _
                            maximumRetryStage = duplicateRetryStage
                        translation.genericC.header.enumMembers( _
                            duplicateIndex).enumValueRetryStage = _
                            duplicateRetryStage
                    End If
                    previousValue = translation.genericC.header.enumMembers( _
                        duplicateIndex).integerValue
                    previousValueKnown = translation.genericC.header.enumMembers( _
                        duplicateIndex).integerValueKnown
                    previousValueRetryStage = translation.genericC.header.enumMembers( _
                        duplicateIndex).enumValueRetryStage
                    If previousValueRetryStage > resolutionStage Then
                        enumNeedsResolution = -1
                        unresolvedMemberCount += 1
                        If unresolvedMemberCount <= 3 Then _
                            unresolvedMemberExamples &= Left(partText, 96) & "; "
                    End If
                    memberCount += 1
                    Continue For
                End If

                Dim integerValue As Long = 0
                Dim integerValueKnown As Long = 0
                Dim integerValueRetryStage As Long = 0
                Dim equalsPosition As Long = InStr(partText, "=")
                If equalsPosition = 0 Then
                    If memberCount = 0 Then
                        integerValueKnown = -1
                    ElseIf previousValueKnown <> 0 AndAlso _
                           previousValue < MAX_GENERIC_ARRAY_COUNT Then
                        integerValue = previousValue + 1
                        integerValueKnown = -1
                    Else
                        integerValueRetryStage = previousValueRetryStage
                    End If
                ElseIf EvaluateGenericEnumIntegerValue( _
                    translation, Trim(Mid(partText, equalsPosition + 1)), _
                    integerValue) <> 0 Then
                    enumValueEvaluationCount += 1
                    integerValueKnown = -1
                Else
                    enumValueEvaluationCount += 1
                    integerValueRetryStage = GenericEnumExpressionRetryStage( _
                        translation, Trim(Mid( _
                            partText, equalsPosition + 1)), resolutionStage)
                End If
                If integerValueRetryStage > maximumRetryStage Then _
                    maximumRetryStage = integerValueRetryStage

                If translation.genericC.header.enumMemberCount >= _
                   MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                    ReportError("generic body exceeds the configured enum constant limit")
                If translation.genericC.header.enumMemberCount > _
                   UBound(translation.genericC.header.enumMembers) Then _
                    ReDim Preserve translation.genericC.header.enumMembers( _
                        0 To UBound(translation.genericC.header.enumMembers) * 2 + 1)
                Dim freeBasicName As String
                Dim isEmitted As Long = 0
                Dim preservedIndex As Long = C2fbStringIndexMapLookup( _
                    preservedEnumMemberIndex, sourceName)
                If preservedIndex >= 0 Then
                    If preservedEnumMembers(preservedIndex).isEmitted <> 0 Then
                        freeBasicName = _
                            preservedEnumMembers(preservedIndex).freeBasicName
                        isEmitted = -1
                    End If
                    If integerValueKnown = 0 AndAlso _
                       preservedEnumMembers(preservedIndex).integerValueKnown <> 0 Then
                        integerValue = _
                            preservedEnumMembers(preservedIndex).integerValue
                        integerValueKnown = -1
                        integerValueRetryStage = 0
                    ElseIf integerValueKnown = 0 AndAlso _
                           integerValueRetryStage = 0 Then
                        integerValueRetryStage = _
                            preservedEnumMembers(preservedIndex).enumValueRetryStage
                    End If
                End If
                If integerValueKnown = 0 Then
                    If integerValueRetryStage > resolutionStage Then
                        enumNeedsResolution = -1
                        unresolvedMemberCount += 1
                        If unresolvedMemberCount <= 3 Then _
                            unresolvedMemberExamples &= Left(partText, 96) & "; "
                    End If
                End If
                Dim isRemoved As Long = CInt( _
                    GenericHeaderEnumMemberRemoved( _
                        translation.sourceUnit.declarations(declarationIndex), _
                        sourceName) <> 0 OrElse enumSourceIncluded = 0)
                If isRemoved = 0 AndAlso isEmitted = 0 Then
                    freeBasicName = GenericSymbolRenameInPolicy( _
                        translation.genericC.policy, sourceName)
                    If freeBasicName = "" Then _
                        freeBasicName = "c2fb_" & sourceName
                    If C2fbFreeBasicIdentifierIsKeyword(freeBasicName) <> 0 Then _
                        freeBasicName &= "_"
                    isEmitted = -1
                End If
                With translation.genericC.header.enumMembers( _
                    translation.genericC.header.enumMemberCount)
                    .sourceName = sourceName
                    .freeBasicName = freeBasicName
                    .enumTypeName = enumTypeName
                    .enumTagName = enumTagName
                    .integerValue = integerValue
                    .integerValueKnown = integerValueKnown
                    .enumValueRetryStage = integerValueRetryStage
                    .isEmitted = isEmitted
                End With
                AddGenericEnumMemberToIndex( _
                    translation, sourceName, _
                    translation.genericC.header.enumMemberCount)
                translation.genericC.header.enumMemberCount += 1
                previousValue = integerValue
                previousValueKnown = integerValueKnown
                previousValueRetryStage = integerValueRetryStage
                memberCount += 1
            Next
            .enumValuesNeedResolution = enumNeedsResolution
            If enumNeedsResolution <> 0 Then
                enumNeedingResolutionCount += 1
                If profileTimings <> 0 Then
                    Dim elapsedSeconds As Double = Timer - enumStartedAt
                    If elapsedSeconds < 0 Then elapsedSeconds += 86400
                    Dim enumName As String = .recordTag
                    If enumName = "" Then enumName = .recordAlias
                    Print "c2fb: generic-body enum pending: " & enumName & _
                        "; values " & Trim(Str(unresolvedMemberCount)) & _
                        "; retry stage " & Trim(Str(maximumRetryStage)) & _
                        "; time " & Trim(Str(elapsedSeconds)) & " seconds"
                    If unresolvedMemberExamples <> "" Then _
                        Print "c2fb: generic-body enum unresolved examples: " & _
                            Left(unresolvedMemberExamples, 288)
                End If
            End If
        End With
    Next

    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) Then Continue For
            For fieldIndex As Long = 0 To .recordFieldCount - 1
                Dim searchPosition As Long = 1
                While searchPosition <= Len(.recordFields(fieldIndex).text)
                    Dim enumBody As String
                    Dim enumStart As Long
                    Dim enumEnd As Long
                    If GenericFindAnonymousEnumBody( _
                        .recordFields(fieldIndex).text, enumBody, _
                        enumStart, enumEnd, searchPosition) = 0 Then Exit While
                    anonymousEnumBodyCount += 1
                    IndexGenericAnonymousEnumBody(translation, enumBody)
                    searchPosition = enumEnd + 1
                Wend
            Next
        End With
    Next
    If profileTimings <> 0 Then
        Print "c2fb: generic-body enum index pass: processed " & _
            Trim(Str(enumDeclarationCount)) & " enum declarations; skipped " & _
            Trim(Str(skippedResolvedEnumCount)) & " resolved declarations; " & _
            Trim(Str(enumNeedingResolutionCount)) & " still need values; evaluated " & _
            Trim(Str(enumValueEvaluationCount)) & " expressions; scanned " & _
            Trim(Str(anonymousEnumBodyCount)) & " anonymous enum bodies"
    End If
End Sub

Private Sub IndexGenericBodyEnumConstantExpressions( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog _
)
    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               .recordKind <> C2FB_RECORD_ENUM Then Continue For
            Dim enumParts() As String
            Dim enumPartCount As Long
            If SplitSimpleCList( _
                .recordBody, enumParts(), enumPartCount, -1, _
                MAX_GENERIC_ENUM_MEMBERS) = 0 Then Continue For
            For partIndex As Long = 0 To enumPartCount - 1
                Dim partText As String = Trim(enumParts(partIndex))
                Dim equalsPosition As Long = InStr(partText, "=")
                If equalsPosition <= 0 Then Continue For
                Dim memberTokens() As String
                Dim memberTokenCount As Long
                TokenizeCDeclaration( _
                    Trim(Left(partText, equalsPosition - 1)), _
                    memberTokens(), memberTokenCount)
                If memberTokenCount <> 1 OrElse _
                   IsIdentifierToken(memberTokens(0)) = 0 Then Continue For
                Dim enumIndex As Long = GenericEnumMemberIndexInContext( _
                    translation, memberTokens(0))
                If enumIndex < 0 OrElse _
                   translation.genericC.header.enumMembers(enumIndex).integerValueKnown <> 0 OrElse _
                   translation.genericC.header.enumMembers(enumIndex).isEmitted <> 0 Then _
                    Continue For

                Dim valueExpression As String = Trim( _
                    Mid(partText, equalsPosition + 1))
                ' The bound evaluator does not know every valid C cast. Keep
                ' any enum expression the body parser can emit as a constant.
                Dim freeBasicExpression As String
                If TranslateGenericEnumExpressionWithBodyParser( _
                    translation, catalog, valueExpression, _
                    freeBasicExpression) <> 0 Then
                    With translation.genericC.header.enumMembers(enumIndex)
                        .freeBasicName = freeBasicExpression
                        .isEmitted = -1
                    End With
                End If
            Next
        End With
    Next
End Sub

Private Function EvaluateGenericHeaderArrayBound( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef arrayCount As Long, _
    ByVal maximumCount As Long = MAX_GENERIC_ARRAY_COUNT, _
    ByVal allowZero As Long = 0 _
) As Long
    Dim sizeofExpression As String
    If ReplaceGenericHeaderSizeofExpressions( _
        translation, sourceExpression, sizeofExpression) = 0 Then Return 0
    Dim numericExpression As String
    If ReplaceGenericEnumNamesWithIntegerValues( _
        translation, sizeofExpression, numericExpression) = 0 Then Return 0
    Return EvaluateSimpleArrayBound( _
        numericExpression, arrayCount, maximumCount, allowZero)
End Function

Private Function TranslateGenericEnumExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String _
) As Long
    Dim normalizedExpression As String
    If RewriteGenericMacroCharacterConstants( _
        sourceExpression, normalizedExpression) = 0 Then Return 0
    sourceExpression = normalizedExpression
    Dim rewritten As String
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceExpression) AndAlso _
                  IsIdentifierPart(Asc(sourceExpression, position)) <> 0
                position += 1
            Wend
            Dim sourceName As String = Mid(sourceExpression, tokenStart, position - tokenStart)
            Dim enumIndex As Long = _
                GenericEnumMemberIndexInContext(translation, sourceName)
            If enumIndex < 0 Then Return 0
            Dim memberReference As String
            If GenericEnumMemberFreeBasicReference( _
                translation, enumIndex, memberReference) = 0 Then Return 0
            rewritten &= memberReference
        ElseIf currentByte >= Asc("0") AndAlso currentByte <= Asc("9") Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceExpression)
                Dim digitByte As Long = Asc(sourceExpression, position)
                If IsIdentifierPart(digitByte) = 0 Then Exit While
                position += 1
            Wend
            rewritten &= Mid(sourceExpression, tokenStart, position - tokenStart)
        Else
            rewritten &= Chr(currentByte)
            position += 1
        End If
    Wend
    Return TranslateGenericHeaderIntegerExpression( _
        translation, rewritten, freeBasicExpression, 0)
End Function

Private Function TranslateGenericEnumExpressionWithCatalog( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String, _
    ByRef integerValue As Long, ByRef integerValueKnown As Long _
) As Long
    integerValue = 0
    integerValueKnown = 0
    If EvaluateGenericEnumIntegerValue( _
        translation, sourceExpression, integerValue) <> 0 Then
        integerValueKnown = -1
        freeBasicExpression = Trim(Str(integerValue))
        Return -1
    End If
    If TranslateGenericEnumExpressionWithBodyParser( _
        translation, catalog, sourceExpression, freeBasicExpression) <> 0 Then _
        Return -1
    Return TranslateGenericEnumExpression( _
        translation, sourceExpression, freeBasicExpression)
End Function

Private Sub WriteGenericAnonymousRecordEnumConstants( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) Then Continue For
            If .removeFromGenericHeader <> 0 OrElse _
               GenericSourceIncludedInPolicy( _
                   translation.genericC.policy, .sourceSpan.startLocation.path) = 0 Then _
                Continue For
            For fieldIndex As Long = 0 To .recordFieldCount - 1
                Dim searchPosition As Long = 1
                While searchPosition <= Len(.recordFields(fieldIndex).text)
                    Dim enumBody As String
                    Dim enumStart As Long
                    Dim enumEnd As Long
                    If GenericFindAnonymousEnumBody( _
                        .recordFields(fieldIndex).text, enumBody, _
                        enumStart, enumEnd, searchPosition) = 0 Then Exit While
                    Dim enumParts() As String
                    Dim enumPartCount As Long
                    If SplitSimpleCList( _
                        enumBody, enumParts(), enumPartCount, -1, _
                        MAX_GENERIC_ENUM_MEMBERS) = 0 Then
                        EmitC2fbSkippedAtLocation( _
                            translation, outputFile, conversionSummary, _
                            "anonymous record enum constants", "", _
                            .sourceSpan.startLocation)
                        searchPosition = enumEnd + 1
                        Continue While
                    End If

                    Dim previousFreeBasicName As String
                    Dim previousFreeBasicExpression As String
                    Dim previousValue As Long = 0
                    Dim previousValueKnown As Long = 0
                    Dim previousWasEmitted As Long = 0
                    Dim memberCount As Long = 0
                    Dim failedExpression As Long = 0
                    For partIndex As Long = 0 To enumPartCount - 1
                        Dim partText As String = Trim(enumParts(partIndex))
                        If partText = "" Then Continue For
                        Dim enumTokens() As String
                        Dim enumTokenCount As Long
                        TokenizeCDeclaration(partText, enumTokens(), enumTokenCount)
                        If enumTokenCount = 0 OrElse _
                           IsIdentifierToken(enumTokens(0)) = 0 Then
                            failedExpression = -1
                            Exit For
                        End If
                        Dim sourceName As String = enumTokens(0)
                        If GenericEnumMemberIndexInContext( _
                            translation, sourceName) >= 0 Then
                            EmitC2fbSkippedAtLocation( _
                                translation, outputFile, conversionSummary, _
                                "duplicate enum constant", sourceName, _
                                .sourceSpan.startLocation, 0)
                            failedExpression = -1
                            Exit For
                        End If

                        Dim freeBasicExpression As String
                        Dim integerValue As Long = 0
                        Dim integerValueKnown As Long = 0
                        Dim equalsPosition As Long = InStr(partText, "=")
                        If equalsPosition = 0 Then
                            If memberCount = 0 Then
                                freeBasicExpression = "0"
                                integerValueKnown = -1
                            ElseIf previousValueKnown <> 0 AndAlso _
                                   previousValue < MAX_GENERIC_ARRAY_COUNT Then
                                integerValue = previousValue + 1
                                integerValueKnown = -1
                                freeBasicExpression = Trim(Str(integerValue))
                            ElseIf previousWasEmitted <> 0 Then
                                freeBasicExpression = previousFreeBasicName & " + 1"
                            ElseIf previousFreeBasicExpression <> "" Then
                                freeBasicExpression = _
                                    previousFreeBasicExpression & " + 1"
                            Else
                                failedExpression = -1
                                Exit For
                            End If
                        Else
                            Dim sourceExpression As String = Trim(Mid( _
                                partText, equalsPosition + 1))
                            If TranslateGenericEnumExpressionWithCatalog( _
                                translation, catalog, sourceExpression, _
                                freeBasicExpression, integerValue, _
                                integerValueKnown) = 0 Then
                                failedExpression = -1
                                Exit For
                            End If
                        End If

                        Dim isRemoved As Long = GenericHeaderEnumMemberRemoved( _
                            translation.sourceUnit.declarations(declarationIndex), _
                            sourceName)
                        Dim freeBasicName As String
                        If isRemoved = 0 Then
                            freeBasicName = GenericFreeBasicFunctionNameInContext( _
                                translation, sourceName, outputNames(), outputNameCount)
                            If outputNameCount > UBound(outputNames) Then _
                                ReDim Preserve outputNames( _
                                    0 To UBound(outputNames) * 2 + 1)
                            outputNames(outputNameCount) = freeBasicName
                            outputNameCount += 1
                        End If
                        If translation.genericC.header.enumMemberCount >= _
                           MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                            ReportError("generic header exceeds the configured enum constant limit")
                        If translation.genericC.header.enumMemberCount > _
                           UBound(translation.genericC.header.enumMembers) Then _
                            ReDim Preserve translation.genericC.header.enumMembers( _
                                0 To UBound(translation.genericC.header.enumMembers) * 2 + 1)
                        With translation.genericC.header.enumMembers( _
                            translation.genericC.header.enumMemberCount)
                            .sourceName = sourceName
                            .freeBasicName = freeBasicName
                            .enumTypeName = ""
                            .enumTagName = ""
                            .integerValue = integerValue
                            .integerValueKnown = integerValueKnown
                            .isEmitted = CInt(isRemoved = 0)
                        End With
                        AddGenericEnumMemberToIndex( _
                            translation, sourceName, _
                            translation.genericC.header.enumMemberCount)
                        translation.genericC.header.enumMemberCount += 1
                        If isRemoved = 0 Then
                            Dim constantBinding As C2fbConstantBindingModel
                            constantBinding.freeBasicName = freeBasicName
                            constantBinding.targetType = "Long"
                            constantBinding.valueExpression = freeBasicExpression
                            WriteGenericConstantBindingWithGuardsInPolicy( _
                                translation.genericC.policy, outputFile, _
                                sourceName, constantBinding)
                        End If
                        previousFreeBasicName = freeBasicName
                        previousFreeBasicExpression = freeBasicExpression
                        previousValue = integerValue
                        previousValueKnown = integerValueKnown
                        previousWasEmitted = CInt(isRemoved = 0)
                        memberCount += 1
                    Next
                    If failedExpression <> 0 Then
                        EmitC2fbSkippedAtLocation( _
                            translation, outputFile, conversionSummary, _
                            "remaining anonymous record enum constants", "", _
                            .sourceSpan.startLocation)
                    End If
                    searchPosition = enumEnd + 1
                Wend
            Next
        End With
    Next
End Sub

Private Sub WriteGenericHeaderEnumConstants( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For entryIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(entryIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               .recordKind <> C2FB_RECORD_ENUM Then Continue For
            If .removeFromGenericHeader <> 0 Then Continue For
            If GenericSourceIncludedInPolicy( _
                translation.genericC.policy, .sourceSpan.startLocation.path) = 0 Then _
                Continue For
            If (.recordTag <> "" AndAlso _
                GenericTypeExcludedInPolicy(translation.genericC.policy, .recordTag) <> 0) OrElse _
               (.recordAlias <> "" AndAlso _
                GenericTypeExcludedInPolicy(translation.genericC.policy, .recordAlias) <> 0) Then
                EmitC2fbSkippedAtLocation(translation, outputFile, conversionSummary, _
                    "excluded enum type", _
                    IIf(.recordTag <> "", .recordTag, .recordAlias), _
                    .sourceSpan.startLocation)
                Continue For
            End If
            If .unsupported <> 0 Then
                EmitC2fbSkippedAtLocation( _
                    translation, outputFile, conversionSummary, _
                    "unsupported enum declaration", _
                    IIf(.recordTag <> "", .recordTag, .recordAlias), _
                    .sourceSpan.startLocation)
                Continue For
            End If
            Dim enumParts() As String
            Dim enumPartCount As Long
            If SplitSimpleCList( _
                .recordBody, enumParts(), enumPartCount, -1, _
                MAX_GENERIC_ENUM_MEMBERS) = 0 Then
                EmitC2fbSkippedAtLocation( _
                    translation, outputFile, conversionSummary, "enum constants", _
                    IIf(.recordTag <> "", .recordTag, .recordAlias), _
                    .sourceSpan.startLocation)
                Continue For
            End If

            Dim previousFreeBasicName As String
            Dim previousSourceName As String
            Dim previousFreeBasicExpression As String
            Dim previousValue As Long = 0
            Dim previousValueKnown As Long = 0
            Dim previousWasEmitted As Long = 0
            Dim failedExpression As Long = 0
            For partIndex As Long = 0 To enumPartCount - 1
                Dim partText As String = Trim(enumParts(partIndex))
                If partText = "" Then Continue For
                Dim enumTokens() As String
                Dim enumTokenCount As Long
                TokenizeCDeclaration(partText, enumTokens(), enumTokenCount)
                If enumTokenCount = 0 OrElse IsIdentifierToken(enumTokens(0)) = 0 Then
                    failedExpression = -1
                    Exit For
                End If
                Dim sourceName As String = enumTokens(0)
                Dim isRemoved As Long = GenericHeaderEnumMemberRemoved( _
                    translation.sourceUnit.declarations(entryIndex), sourceName)
                Dim equalsPosition As Long = InStr(partText, "=")
                Dim freeBasicExpression As String
                Dim integerValue As Long = 0
                Dim integerValueKnown As Long = 0
                If equalsPosition = 0 Then
                    If previousSourceName = "" Then
                        freeBasicExpression = "0"
                        integerValueKnown = -1
                    ElseIf previousWasEmitted <> 0 Then
                        freeBasicExpression = previousFreeBasicName & " + 1"
                        If previousValueKnown <> 0 AndAlso _
                           previousValue < MAX_GENERIC_ARRAY_COUNT Then
                            integerValue = previousValue + 1
                            integerValueKnown = -1
                        End If
                    ElseIf previousValueKnown <> 0 AndAlso _
                           previousValue < MAX_GENERIC_ARRAY_COUNT Then
                        integerValue = previousValue + 1
                        integerValueKnown = -1
                        freeBasicExpression = Trim(Str(integerValue))
                    Else
                        freeBasicExpression = previousFreeBasicExpression & " + 1"
                    End If
                Else
                    ' Equality operators in an enum value are not another assignment.
                    If FindSimpleAssignmentEquals(partText) <> equalsPosition OrElse _
                       TranslateGenericEnumExpressionWithCatalog( _
                           translation, catalog, _
                           Trim(Mid(partText, equalsPosition + 1)), _
                           freeBasicExpression, integerValue, _
                           integerValueKnown) = 0 Then
                        failedExpression = -1
                        Exit For
                    End If
                End If

                If GenericEnumMemberIndexInContext(translation, sourceName) >= 0 Then
                    EmitC2fbSkippedAtLocation(translation,  _
                        outputFile, conversionSummary, "duplicate enum constant", sourceName, _
                        .sourceSpan.startLocation, 0)
                    failedExpression = -1
                    Exit For
                End If
                Dim freeBasicName As String
                If isRemoved = 0 Then
                    freeBasicName = GenericFreeBasicFunctionNameInContext( _
                        translation, sourceName, outputNames(), outputNameCount)
                    If outputNameCount > UBound(outputNames) Then _
                        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                    outputNames(outputNameCount) = freeBasicName
                    outputNameCount += 1
                End If
                If translation.genericC.header.enumMemberCount >= _
                   MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                    ReportError("generic header exceeds the configured enum constant limit")
                If translation.genericC.header.enumMemberCount > UBound(translation.genericC.header.enumMembers) Then _
                    ReDim Preserve translation.genericC.header.enumMembers(0 To UBound(translation.genericC.header.enumMembers) * 2 + 1)
                With translation.genericC.header.enumMembers( _
                    translation.genericC.header.enumMemberCount)
                    .sourceName = sourceName
                    .freeBasicName = freeBasicName
                    .integerValue = integerValue
                    .integerValueKnown = integerValueKnown
                    .isEmitted = CInt(isRemoved = 0)
                End With
                AddGenericEnumMemberToIndex( _
                    translation, sourceName, _
                    translation.genericC.header.enumMemberCount)
                translation.genericC.header.enumMemberCount += 1
                If isRemoved = 0 Then
                    Dim constantBinding As C2fbConstantBindingModel
                    constantBinding.freeBasicName = freeBasicName
                    constantBinding.targetType = "Long"
                    constantBinding.valueExpression = freeBasicExpression
                    WriteGenericConstantBindingWithGuardsInPolicy( _
                        translation.genericC.policy, outputFile, sourceName, constantBinding)
                End If
                previousFreeBasicName = freeBasicName
                previousSourceName = sourceName
                previousFreeBasicExpression = freeBasicExpression
                previousValue = integerValue
                previousValueKnown = integerValueKnown
                previousWasEmitted = CInt(isRemoved = 0)
            Next
            If failedExpression <> 0 Then
                EmitC2fbSkippedAtLocation(translation,  _
                    outputFile, conversionSummary, _
                    "remaining enum constants after an unsupported value", _
                    IIf(.recordTag <> "", .recordTag, .recordAlias), _
                    .sourceSpan.startLocation)
            End If
        End With
    Next
    WriteGenericAnonymousRecordEnumConstants( _
        translation, catalog, outputFile, outputNames(), outputNameCount, _
        conversionSummary)
    If translation.genericC.header.enumMemberCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

/' end of c2fb_generic_enums.bi '/
