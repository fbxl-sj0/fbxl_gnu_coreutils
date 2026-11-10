/'
    Project: C2FB body lowering

    File: c2fb_body_statements.bi

    Purpose:

        Parse supported C statements and lower them to conservative FreeBASIC.

    Responsibilities:

        - Parse statements, blocks, and supported ordinary control flow.
        - Lower returns, assignments, and jumps.
        - Preserve storage and lvalue behavior for supported record compound
          literals used as expressions.
        - Delegate switch statements to the shared switch state machine.
        - Preserve the first detailed parse failure for shared diagnostics.
        - Consume shared local declaration and expression-lowering helpers.

    This file intentionally does NOT contain:

        - Procedure-signature conversion or function candidate assembly.
        - C source collection, preprocessing, or generated-file output.
'/

Declare Function ParseSimpleCStatement( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef sourceText As String, _
    ByRef position As Long, _
    ByRef outputText As String, _
    ByVal indentText As String, _
    ByVal returnType As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, _
    ByVal callableCount As Long, _
    parameterNames() As String, _
    parameterAliases() As String, _
    parameterTypes() As String, _
    ByRef symbolCount As Long, _
    locals() As SimpleLocalVariable, _
    ByRef localCount As Long, _
    ByRef terminatesPaths As Long, _
    ByVal allowBodyReplacements As Long = -1 _
) As Long

Declare Function TranslateSimpleReturnValue( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal returnType As String, _
    ByRef sourceExpression As String, _
    ByRef translatedExpression As String, _
    ByRef expressionPrelude As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, _
    ByVal callableCount As Long, _
    parameterNames() As String, _
    parameterAliases() As String, _
    parameterTypes() As String, _
    ByVal parameterCount As Long _
) As Long

Declare Function ReadSimpleCStatement( _
    ByRef sourceText As String, _
    ByRef position As Long, _
    ByRef statementText As String _
) As Long

Declare Function ParseSimpleSwitchStatement( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef sourceText As String, _
    ByRef position As Long, _
    ByRef outputText As String, _
    ByVal indentText As String, _
    ByVal returnType As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, _
    ByVal callableCount As Long, _
    parameterNames() As String, _
    parameterAliases() As String, _
    parameterTypes() As String, _
    ByRef symbolCount As Long, _
    locals() As SimpleLocalVariable, _
    ByRef localCount As Long, _
    ByRef terminatesPaths As Long _
) As Long

Declare Function IsSimpleSwitchLabel( _
    ByVal sourceText As String, ByVal position As Long _
) As Long

Declare Function SimpleCConditionConstantValue( _
    ByRef translation As C2fbTranslationContext, _
    ByVal conditionText As String, _
    parameterNames() As String, parameterAliases() As String, _
    ByVal parameterCount As Long, ByRef conditionValue As Long _
) As Long

Declare Function SimpleCStatementAlwaysTerminates( _
    ByRef translation As C2fbTranslationContext, _
    ByVal statementText As String, _
    parameterNames() As String, parameterAliases() As String, _
    ByVal parameterCount As Long _
) As Long

Private Function ReadSimpleReturn( _
    ByRef sourceText As String, _
    ByRef position As Long, _
    ByRef returnExpression As String _
) As Long
    SkipCSpaces(sourceText, position)
    If Mid(sourceText, position, 6) <> "return" Then Return 0
    If position + 6 <= Len(sourceText) AndAlso _
       IsIdentifierPart(Asc(sourceText, position + 6)) <> 0 Then Return 0

    position += 6
    SkipCSpaces(sourceText, position)
    Return ReadSimpleCStatement(sourceText, position, returnExpression)
End Function

Private Function ReadSimpleIfCondition( _
    ByRef sourceText As String, _
    ByRef position As Long, _
    ByRef conditionText As String _
) As Long
    SkipCSpaces(sourceText, position)
    If Mid(sourceText, position, 2) <> "if" Then Return 0
    If position + 2 <= Len(sourceText) AndAlso _
       IsIdentifierPart(Asc(sourceText, position + 2)) <> 0 Then Return 0
    position += 2
    SkipCSpaces(sourceText, position)
    If position > Len(sourceText) OrElse Asc(sourceText, position) <> Asc("(") Then Return 0

    Dim conditionStart As Long = position + 1
    If ScanSimpleExpressionGroup(sourceText, position, Asc("("), Asc(")")) = 0 Then Return 0
    conditionText = Trim(Mid(sourceText, conditionStart, position - conditionStart - 1))
    If Len(conditionText) = 0 Then Return 0
    Return -1
End Function

Private Function TranslateSimpleReturnValue( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal returnType As String, ByRef sourceExpression As String, _
    ByRef translatedExpression As String, ByRef expressionPrelude As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    translatedExpression = ""
    expressionPrelude = ""
    If returnType = "void" Then
        If Len(sourceExpression) <> 0 Then Return 0
        expressionPrelude = SimpleAllocaCleanupText(context)
        Return -1
    End If
    If Len(sourceExpression) = 0 Then Return 0
    If TranslateSequencedExpression(translation, catalog, _
                                    sourceExpression, translatedExpression, expressionPrelude, context, _
                                    callableNames(), callableCount, parameterNames(), parameterAliases(), _
                                    parameterTypes(), parameterCount, returnType) = 0 Then Return 0
    If context.allocaHeadName <> "" Then
        Dim returnTemporary As String = _
            NewSimpleBodyTemporary(context, returnType, "")
        If returnTemporary = "" Then Return 0
        expressionPrelude &= returnTemporary & " = " & translatedExpression & Chr(10)
        translatedExpression = returnTemporary
        expressionPrelude &= SimpleAllocaCleanupText(context) & Chr(10)
    End If
    Return -1
End Function

Private Function ReadSimpleCStatement( _
    ByRef sourceText As String, _
    ByRef position As Long, _
    ByRef statementText As String _
) As Long
    SkipCSpaces(sourceText, position)
    If position > Len(sourceText) Then Return 0

    Dim startPosition As Long = position
    Dim parenDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quote As Long = 0
    Dim escaped As Long = 0
    While position <= Len(sourceText)
        Dim c As Long = Asc(sourceText, position)
        If quote <> 0 Then
            If escaped <> 0 Then
                escaped = 0
            ElseIf c = Asc(Chr(92)) Then
                escaped = -1
            ElseIf c = quote Then
                quote = 0
            End If
        ElseIf c = Asc(Chr(34)) OrElse c = Asc("'") Then
            quote = c
        ElseIf c = Asc("(") Then
            parenDepth += 1
        ElseIf c = Asc(")") Then
            parenDepth -= 1
            If parenDepth < 0 Then Return 0
        ElseIf c = Asc("{") Then
            braceDepth += 1
        ElseIf c = Asc("}") Then
            If braceDepth = 0 Then Return 0
            braceDepth -= 1
        ElseIf parenDepth = 0 AndAlso braceDepth = 0 AndAlso c = Asc(";") Then
            statementText = Trim(Mid(sourceText, startPosition, position - startPosition))
            position += 1
            Return -1
        End If
        position += 1
    Wend
    Return 0
End Function

Private Function IsSimpleUnusedParameterStatement( _
    ByVal statementText As String _
) As Long
    Dim position As Long = 1
    While position <= Len(statementText)
        While position <= Len(statementText) AndAlso _
              IsSpaceByte(Asc(statementText, position)) <> 0
            position += 1
        Wend
        If Mid(statementText, position, 6) <> "(void)" Then Return 0
        position += 6

        While position <= Len(statementText) AndAlso _
              IsSpaceByte(Asc(statementText, position)) <> 0
            position += 1
        Wend
        If position > Len(statementText) OrElse _
           Asc(statementText, position) <> Asc("(") Then Return 0
        position += 1

        While position <= Len(statementText) AndAlso _
              IsSpaceByte(Asc(statementText, position)) <> 0
            position += 1
        Wend
        If position > Len(statementText) OrElse _
           IsIdentifierStart(Asc(statementText, position)) = 0 Then Return 0
        position += 1
        While position <= Len(statementText) AndAlso _
              IsIdentifierPart(Asc(statementText, position)) <> 0
            position += 1
        Wend
        While position <= Len(statementText) AndAlso _
              IsSpaceByte(Asc(statementText, position)) <> 0
            position += 1
        Wend
        If position > Len(statementText) OrElse _
           Asc(statementText, position) <> Asc(")") Then Return 0
        position += 1

        While position <= Len(statementText) AndAlso _
              IsSpaceByte(Asc(statementText, position)) <> 0
            position += 1
        Wend
        If position > Len(statementText) Then Return -1
        If Asc(statementText, position) <> Asc(",") Then Return 0
        position += 1
    Wend
    Return 0
End Function

Private Function IsSimpleVoidZeroStatement(ByVal statementText As String) As Long
    ' SQLite's disabled assertions expand to nested parentheses around void
    ' zero. No operand is evaluated. Other discarded expressions stay intact.
    Dim compact As String
    For i As Long = 1 To Len(statementText)
        If IsSpaceByte(Asc(statementText, i)) = 0 Then compact &= Mid(statementText, i, 1)
    Next
    While Len(compact) > 1 AndAlso Left(compact, 1) = "("
        Dim position As Long = 1
        If ScanSimpleExpressionGroup(compact, position, Asc("("), Asc(")")) = 0 Then Return 0
        If position <> Len(compact) + 1 Then Exit While
        compact = Mid(compact, 2, Len(compact) - 2)
    Wend
    If Left(compact, 6) <> "(void)" Then Return 0
    compact = Mid(compact, 7)
    While Len(compact) > 1 AndAlso Left(compact, 1) = "("
        Dim position As Long = 1
        If ScanSimpleExpressionGroup(compact, position, Asc("("), Asc(")")) = 0 Then Return 0
        If position <> Len(compact) + 1 Then Exit While
        compact = Mid(compact, 2, Len(compact) - 2)
    Wend
    If compact = "0" Then Return -1
    ' SQLite also casts a plain local identifier to void to suppress unused
    ' warnings. Calls and other effectful expressions remain translated.
    Return CInt(IsIdentifierToken(compact) <> 0)
End Function



Private Function ParseSimpleArrayCompoundLiteralInitializer( _
    ByVal sourceText As String, ByVal nextIndex As Long, _
    ByRef targetIndex As Long, ByRef initializerValue As String, _
    ByRef hasMemberDesignator As Long, _
    ByRef context As SimpleBodyContext _
) As Long
    sourceText = Trim(sourceText)
    targetIndex = nextIndex
    initializerValue = sourceText
    hasMemberDesignator = 0
    If Left(sourceText, 1) <> "[" Then Return -1

    Dim designatorEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceText, designatorEnd, Asc("["), Asc("]")) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-array-compound-literal-designator", _
            "malformed array compound literal index designator: " & _
            Left(sourceText, 80))
        Return 0
    End If
    Dim indexExpression As String = Trim(Mid(sourceText, 2, designatorEnd - 3))
    If EvaluateSimpleArrayBound( _
        indexExpression, targetIndex, MAX_SIMPLE_ARRAY_COUNT - 1, -1) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-array-compound-literal-designator", _
            "array compound literal index designator is not a supported " & _
            "nonnegative constant: " & Left(indexExpression, 80))
        Return 0
    End If
    SkipCSpaces(sourceText, designatorEnd)
    If designatorEnd > Len(sourceText) Then
        RecordSimpleBodyFailure( _
            context, "unsupported-array-compound-literal-designator", _
            "array compound literal index designator has no initializer")
        Return 0
    End If
    If Asc(sourceText, designatorEnd) = Asc("=") Then
        designatorEnd += 1
        initializerValue = Trim(Mid(sourceText, designatorEnd))
    ElseIf Asc(sourceText, designatorEnd) = Asc(".") Then
        initializerValue = Trim(Mid(sourceText, designatorEnd))
        Dim fieldName As String
        Dim fieldInitializer As String
        If ParseSimpleCMemberDesignator( _
            initializerValue, fieldName, fieldInitializer) = 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-array-compound-literal-member-designator", _
                "unsupported array element member designator: " & _
                Left(initializerValue, 120))
            Return 0
        End If
        initializerValue = "{ " & initializerValue & " }"
        hasMemberDesignator = -1
    Else
        RecordSimpleBodyFailure( _
            context, "unsupported-array-compound-literal-designator", _
            "only [constant-index] and [constant-index].member designators " & _
            "are supported")
        Return 0
    End If
    If initializerValue = "" Then
        RecordSimpleBodyFailure( _
            context, "unsupported-array-compound-literal-initializer", _
            "array compound literal designator has no initializer")
        Return 0
    End If
    Return -1
End Function

Private Function InferSimpleArrayCompoundLiteralBound( _
    values() As String, ByVal valueCount As Long, _
    ByRef arrayCount As Long, ByRef context As SimpleBodyContext _
) As Long
    arrayCount = 0
    Dim nextIndex As Long = 0
    For valueIndex As Long = 0 To valueCount - 1
        Dim initializerValue As String = Trim(values(valueIndex))
        If Left(initializerValue, 1) = "[" Then
            Dim designatorEnd As Long = 1
            If ScanSimpleExpressionGroup( _
                initializerValue, designatorEnd, Asc("["), Asc("]")) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-inferred-array-compound-literal-designator", _
                    "malformed array compound literal index designator: " & _
                    Left(initializerValue, 80))
                Return 0
            End If
            Dim designatorIndex As Long
            If EvaluateSimpleArrayBound( _
                Trim(Mid(initializerValue, 2, designatorEnd - 3)), _
                designatorIndex, MAX_SIMPLE_ARRAY_COUNT - 1, -1) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-inferred-array-compound-literal-designator", _
                    "array compound literal index designator is not a " & _
                    "supported nonnegative constant")
                Return 0
            End If
            SkipCSpaces(initializerValue, designatorEnd)
            If designatorEnd > Len(initializerValue) OrElse _
               (Asc(initializerValue, designatorEnd) <> Asc("=") AndAlso _
                Asc(initializerValue, designatorEnd) <> Asc(".")) Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-inferred-array-compound-literal-designator", _
                    "unsupported array compound literal designator " & _
                    Left(initializerValue, 80))
                Return 0
            End If
            nextIndex = designatorIndex
        End If
        If nextIndex >= MAX_SIMPLE_ARRAY_COUNT Then
            RecordSimpleBodyFailure( _
                context, "array-compound-literal-limit-exceeded", _
                "compound literal array size must be between 1 and " & _
                Trim(Str(MAX_SIMPLE_ARRAY_COUNT)))
            Return 0
        End If
        If nextIndex + 1 > arrayCount Then arrayCount = nextIndex + 1
        nextIndex += 1
    Next
    Return CInt(arrayCount > 0)
End Function

Private Function LowerSimpleCompoundLiteralArrayValue( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal typeText As String, ByVal aggregateText As String, _
    ByVal targetName As String, ByVal targetType As String, _
    ByRef pointerType As String, ByRef pointerExpression As String, _
    ByRef outputPrelude As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByRef symbolCount As Long, _
    ByRef arrayCountOutput As Long, ByVal inspectOnly As Long = 0 _
) As Long
    pointerType = ""
    pointerExpression = ""
    outputPrelude = ""
    arrayCountOutput = 0
    Dim arrayOpen As Long = InStr(typeText, "[")
    Dim arrayClose As Long = InStr(arrayOpen + 1, typeText, "]")
    If arrayOpen <= 1 OrElse arrayClose <= arrayOpen OrElse _
       Trim(Mid(typeText, arrayClose + 1)) <> "" OrElse _
       InStr(Mid(typeText, arrayOpen + 1, arrayClose - arrayOpen - 1), "[") <> 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-array-compound-literal-type", _
            "compound literal requires a one-dimensional C array type")
        Return 0
    End If
    Dim elementTypeText As String = Trim(Left(typeText, arrayOpen - 1))
    Dim boundText As String = Trim(Mid( _
        typeText, arrayOpen + 1, arrayClose - arrayOpen - 1))
    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(elementTypeText, typeTokens(), typeTokenCount)
    If typeTokenCount <= 0 Then Return 0
    Dim resolvedElementType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel(translation, catalog, typeTokens(), 0, _
                         typeTokenCount - 1, resolvedElementType, _
                         C2FB_POINTER_MAPPING_PRESERVE, _
                         C2FB_TYPE_MAPPING_BODY, _
                         C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
    If resolvedElementType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then
        RecordSimpleBodyFailure( _
            context, "unsupported-array-compound-literal-element-type", _
            "cannot resolve compound literal array element type " & elementTypeText)
        Return 0
    End If
    Dim elementType As String = resolvedElementType.freeBasicType
    Dim storageType As String = elementType
    If resolvedElementType.isConst <> 0 AndAlso _
       InStr(storageType, " Ptr") = 0 AndAlso _
       Left(storageType, 6) = "Const " Then
        storageType = Mid(storageType, 7)
    End If
    Dim normalizedElementType As String = NormalizeFbBodyType(catalog, storageType)
    If targetType <> "" Then
        Dim targetElementType As String = SimplePointeeType(targetType)
        Dim normalizedTargetType As String = NormalizeFbBodyType( _
            catalog, targetElementType)
        If targetElementType = "" OrElse normalizedTargetType = "Any" OrElse _
           normalizedElementType <> normalizedTargetType OrElse _
           (resolvedElementType.isConst <> 0 AndAlso _
            Left(targetType, 6) <> "Const ") Then
            RecordSimpleBodyFailure( _
                context, "incompatible-array-compound-literal-assignment", _
                "compound literal array element type does not match pointer " & _
                targetName)
            Return 0
        End If
        pointerType = targetType
    Else
        pointerType = storageType & " Ptr"
        If resolvedElementType.isConst <> 0 Then _
            pointerType = "Const " & pointerType
    End If

    Dim values() As String
    Dim valueCount As Long = 0
    Dim isStringInitializer As Long = 0
    Dim initializerBody As String = Trim(aggregateText)
    If Left(initializerBody, 1) <> "{" OrElse _
       Right(initializerBody, 1) <> "}" Then Return 0
    initializerBody = Trim(Mid( _
        initializerBody, 2, Len(initializerBody) - 2))
    If Right(initializerBody, 1) = "," Then _
        initializerBody = RTrim(Left(initializerBody, Len(initializerBody) - 1))
    If Left(initializerBody, 1) = Chr(34) Then
        If storageType <> "Byte" AndAlso storageType <> "UByte" AndAlso _
           storageType <> "c2fb_c_char" AndAlso _
           storageType <> "c2fb_c_uchar" Then
            RecordSimpleBodyFailure( _
                context, "unsupported-array-compound-literal-string", _
                "string initializer does not match compound literal array type")
            Return 0
        End If
        Dim stringValues As String
        Dim stringByteCount As Long
        If ReadSimpleStaticStringArray( _
            initializerBody, stringValues, stringByteCount) = 0 OrElse _
           SplitSimpleCList(stringValues, values(), valueCount) = 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-array-compound-literal-string", _
                "unsupported compound literal string initializer")
            Return 0
        End If
        isStringInitializer = -1
    ElseIf initializerBody <> "" Then
        If SplitSimpleCList(initializerBody, values(), valueCount) = 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-array-compound-literal-initializer", _
                "unsupported compound literal array initializer")
            Return 0
        End If
    End If

    Dim arrayCount As Long
    If boundText = "" Then
        If isStringInitializer = 0 Then
            If InferSimpleArrayCompoundLiteralBound( _
                values(), valueCount, arrayCount, context) = 0 Then Return 0
        Else
            arrayCount = valueCount
        End If
    ElseIf EvaluateSimpleArrayBound( _
        boundText, arrayCount, MAX_SIMPLE_ARRAY_COUNT) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-array-compound-literal-bound", _
            "unsupported compound literal array bound " & boundText)
        Return 0
    End If
    If isStringInitializer <> 0 AndAlso _
       arrayCount > 0 AndAlso valueCount = arrayCount + 1 AndAlso _
       Trim(values(arrayCount)) = "0" Then valueCount -= 1
    If arrayCount < 1 OrElse arrayCount > MAX_SIMPLE_ARRAY_COUNT OrElse _
       (boundText = "" AndAlso valueCount = 0) Then
        RecordSimpleBodyFailure( _
            context, "array-compound-literal-limit-exceeded", _
            "compound literal array size must be between 1 and " & _
            Trim(Str(MAX_SIMPLE_ARRAY_COUNT)))
        Return 0
    End If

    arrayCountOutput = arrayCount
    If inspectOnly <> 0 Then
        pointerExpression = "CPtr(" & pointerType & ", 0)"
        Return -1
    End If

    Dim initializerIndexes() As Long
    Dim initializerMemberDesignators() As Long
    Dim initializerSkipped() As Long
    If valueCount > 0 Then ReDim initializerIndexes(0 To valueCount - 1)
    If valueCount > 0 Then ReDim initializerMemberDesignators(0 To valueCount - 1)
    If valueCount > 0 Then ReDim initializerSkipped(0 To valueCount - 1)
    Dim nextIndex As Long = 0
    For valueIndex As Long = 0 To valueCount - 1
        Dim initializerValue As String
        Dim targetIndex As Long
        Dim hasMemberDesignator As Long
        If ParseSimpleArrayCompoundLiteralInitializer( _
            values(valueIndex), nextIndex, targetIndex, initializerValue, _
            hasMemberDesignator, context) = 0 Then Return 0
        If targetIndex < 0 OrElse targetIndex >= arrayCount Then
            RecordSimpleBodyFailure( _
                context, "array-compound-literal-index-out-of-range", _
                "array compound literal initializer index " & _
                Trim(Str(targetIndex)) & " is outside the array bound " & _
                Trim(Str(arrayCount)))
            Return 0
        End If
        values(valueIndex) = initializerValue
        initializerIndexes(valueIndex) = targetIndex
        initializerMemberDesignators(valueIndex) = hasMemberDesignator
        nextIndex = targetIndex + 1
    Next
    For valueIndex As Long = 0 To valueCount - 1
        If initializerSkipped(valueIndex) <> 0 Then Continue For
        Dim firstLaterIndex As Long = valueIndex + 1
        If initializerMemberDesignators(valueIndex) <> 0 Then
            While firstLaterIndex < valueCount AndAlso _
                  initializerIndexes(firstLaterIndex) = _
                      initializerIndexes(valueIndex) AndAlso _
                  initializerMemberDesignators(firstLaterIndex) <> 0
                Dim firstMemberPath As String
                Dim laterMemberPath As String
                If SimpleCMemberDesignatorPath( _
                    values(valueIndex), firstMemberPath) <> 0 AndAlso _
                   SimpleCMemberDesignatorPath( _
                    values(firstLaterIndex), laterMemberPath) <> 0 AndAlso _
                   firstMemberPath = laterMemberPath Then
                    ' C does not evaluate earlier initializers for the same
                    ' subobject, so only the final expression is retained.
                    values(valueIndex) = values(firstLaterIndex)
                    initializerSkipped(firstLaterIndex) = -1
                    firstLaterIndex += 1
                    Continue While
                End If
                Dim mergedInitializer As String
                If MergeSimpleCMemberDesignatorInitializers( _
                    values(valueIndex), values(firstLaterIndex), _
                    mergedInitializer, 0, -1) = 0 Then
                    RecordSimpleBodyFailure( _
                        context, "repeated-array-compound-literal-member-designator", _
                        "record member initializers for one array element " & _
                        "cannot be merged without changing C initialization semantics")
                    Return 0
                End If
                values(valueIndex) = mergedInitializer
                initializerSkipped(firstLaterIndex) = -1
                firstLaterIndex += 1
            Wend
        End If
        For laterIndex As Long = firstLaterIndex To valueCount - 1
            If initializerIndexes(laterIndex) <> initializerIndexes(valueIndex) Then _
                Continue For
            If initializerMemberDesignators(valueIndex) <> 0 OrElse _
               initializerMemberDesignators(laterIndex) <> 0 Then
                RecordSimpleBodyFailure( _
                    context, "repeated-array-compound-literal-member-designator", _
                    "nonconsecutive initializers for one array element " & _
                    "cannot be merged without changing C initialization order")
                Return 0
            End If
        Next
    Next
    If context.temporarySerial >= MAX_EXPRESSION_TEMPORARIES Then
        RecordSimpleBodyFailure( _
            context, "compound-literal-workspace-limit", _
            "too many compound literal arrays in this C procedure")
        Return 0
    End If
    Dim arrayName As String = _
        "c2fb_compound_array_" & Trim(Str(context.temporarySerial))
    context.temporarySerial += 1
    context.declarations &= "    Dim " & arrayName & "(0 To " & _
        Trim(Str(arrayCount - 1)) & ") As " & storageType & Chr(10)
    If resolvedElementType.isConst <> 0 Then _
        context.readOnlyAliases &= "|" & arrayName & "|"

    Dim elementRecord As String
    If InStr(storageType, " Ptr") = 0 AndAlso _
       IsCBodyCallbackTypeInContext(translation, storageType) = 0 Then _
        elementRecord = CBodyRecordName(translation, catalog, storageType)
    If SimpleArithmeticKind(catalog, storageType) = 0 AndAlso _
       InStr(storageType, " Ptr") = 0 AndAlso _
       IsCBodyCallbackTypeInContext(translation, storageType) = 0 AndAlso _
       elementRecord = "" Then
        RecordSimpleBodyFailure( _
            context, "unsupported-array-compound-literal-element", _
            "unsupported compound literal array element type " & storageType)
        Return 0
    End If

    For arrayIndex As Long = 0 To arrayCount - 1
        Dim elementValue As String
        If elementRecord <> "" Then
            If TranslateSimpleRecordInitializer( _
                translation, catalog, "{}", storageType, elementValue, _
                context, callableNames(), callableCount, parameterNames(), _
                parameterAliases(), parameterTypes(), symbolCount) = 0 Then _
                Return 0
        ElseIf InStr(storageType, " Ptr") <> 0 OrElse _
               IsCBodyCallbackTypeInContext(translation, storageType) <> 0 Then
            elementValue = "CPtr(" & storageType & ", 0)"
        Else
            elementValue = "Cast(" & storageType & ", 0)"
        End If
        If outputPrelude <> "" AndAlso _
           Right(outputPrelude, 1) <> Chr(10) Then _
            outputPrelude &= Chr(10)
        outputPrelude &= arrayName & "(" & Trim(Str(arrayIndex)) & ") = " & _
                         elementValue & Chr(10)
    Next

    For valueIndex As Long = 0 To valueCount - 1
        If initializerSkipped(valueIndex) <> 0 Then Continue For
        Dim isOverridden As Long = 0
        For laterIndex As Long = valueIndex + 1 To valueCount - 1
            If initializerSkipped(laterIndex) <> 0 Then Continue For
            If initializerIndexes(laterIndex) = initializerIndexes(valueIndex) Then
                isOverridden = -1
                Exit For
            End If
        Next
        If isOverridden <> 0 Then Continue For

        Dim elementValue As String
        If elementRecord <> "" Then
            Dim recordInitializerPrelude As String
            If TranslateSimpleRecordInitializerWithPrelude( _
                translation, catalog, values(valueIndex), storageType, _
                elementValue, recordInitializerPrelude, context, _
                callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                symbolCount) = 0 Then Return 0
            If recordInitializerPrelude <> "" Then
                If outputPrelude <> "" AndAlso _
                   Right(outputPrelude, 1) <> Chr(10) Then _
                    outputPrelude &= Chr(10)
                outputPrelude &= RTrim(recordInitializerPrelude, Any Chr(10))
                If Right(outputPrelude, 1) <> Chr(10) Then _
                    outputPrelude &= Chr(10)
            End If
        Else
            Dim elementPrelude As String
            If TranslateSequencedExpression( _
                translation, catalog, values(valueIndex), elementValue, _
                elementPrelude, context, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                symbolCount, storageType) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-array-compound-literal-element", _
                    "unsupported compound literal array element: " & _
                    Left(values(valueIndex), 120))
                Return 0
            End If
            If elementPrelude <> "" Then
                If outputPrelude <> "" AndAlso _
                   Right(outputPrelude, 1) <> Chr(10) Then _
                    outputPrelude &= Chr(10)
                outputPrelude &= RTrim(elementPrelude, Any Chr(10))
                If Right(outputPrelude, 1) <> Chr(10) Then _
                    outputPrelude &= Chr(10)
            End If
        End If
        If outputPrelude <> "" AndAlso _
           Right(outputPrelude, 1) <> Chr(10) Then _
            outputPrelude &= Chr(10)
        outputPrelude &= arrayName & "(" & _
            Trim(Str(initializerIndexes(valueIndex))) & ") = " & _
            elementValue & Chr(10)
    Next
    pointerExpression = "CPtr(" & pointerType & ", @" & arrayName & "(0))"
    Return -1
End Function

Private Function TranslateSimpleCompoundLiteralAssignment( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, ByRef outputText As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal symbolCount As Long _
) As Long
    outputText = ""
    Dim text As String = Trim(statementText)
    Dim assignmentPosition As Long = FindSimpleAssignmentEquals(text)
    If assignmentPosition = 0 Then Return 0
    Dim targetName As String = Trim(Left(text, assignmentPosition - 1))
    If IsIdentifierToken(targetName) = 0 Then Return 0
    Dim sourceType As String = ""
    Dim targetAlias As String = ""
    For symbolIndex As Long = 0 To symbolCount - 1
        If parameterNames(symbolIndex) = targetName Then
            sourceType = parameterTypes(symbolIndex)
            targetAlias = parameterAliases(symbolIndex)
            Exit For
        End If
    Next
    If sourceType = "" OrElse targetAlias = "" OrElse _
       InStr(sourceType, "[]") <> 0 Then Return 0

    Dim initializerText As String = Trim(Mid(text, assignmentPosition + 1))
    Dim position As Long = 1
    SkipCSpaces(initializerText, position)
    If position > Len(initializerText) OrElse _
       Asc(initializerText, position) <> Asc("(") Then Return 0
    Dim typeStart As Long = position + 1
    If ScanSimpleExpressionGroup( _
        initializerText, position, Asc("("), Asc(")")) = 0 Then Return 0
    Dim typeText As String = Trim(Mid( _
        initializerText, typeStart, position - typeStart - 1))
    SkipCSpaces(initializerText, position)
    If position > Len(initializerText) OrElse _
       Asc(initializerText, position) <> Asc("{") Then Return 0
    Dim aggregateStart As Long = position
    If ScanSimpleExpressionGroup( _
        initializerText, position, Asc("{"), Asc("}")) = 0 Then Return 0
    SkipCSpaces(initializerText, position)
    If position <= Len(initializerText) Then Return 0

    If InStr(typeText, "[") <> 0 Then
        If InStr(sourceType, " Ptr") = 0 Then
            RecordSimpleBodyFailure( _
                context, "incompatible-array-compound-literal-assignment", _
                "array compound literal requires a compatible pointer destination " & _
                targetName)
            Return 0
        End If
        If InStr(context.readOnlyAliases, "|" & targetAlias & "|") <> 0 Then
            RecordSimpleBodyFailure( _
                context, "compound-literal-assignment-to-const", _
                "cannot assign a compound literal to const C object " & targetName)
            Return 0
        End If
        Dim pointerType As String
        Dim pointerExpression As String
        Dim arrayPrelude As String
        Dim arrayCount As Long
        If LowerSimpleCompoundLiteralArrayValue( _
            translation, catalog, typeText, _
            Mid(initializerText, aggregateStart, position - aggregateStart), _
            targetName, sourceType, pointerType, pointerExpression, _
            arrayPrelude, context, callableNames(), callableCount, _
            parameterNames(), parameterAliases(), parameterTypes(), _
            symbolCount, arrayCount) = 0 Then Return 0
        outputText = arrayPrelude & targetAlias & " = " & pointerExpression
        Return -1
    End If

    If InStr(sourceType, " Ptr") <> 0 OrElse _
       CBodyRecordName(translation, catalog, sourceType) = "" Then Return 0
    If InStr(context.readOnlyAliases, "|" & targetAlias & "|") <> 0 Then
        RecordSimpleBodyFailure( _
            context, "compound-literal-assignment-to-const", _
            "cannot assign a compound literal to const C object " & targetName)
        Return 0
    End If

    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(typeText, typeTokens(), typeTokenCount)
    If typeTokenCount <= 0 Then Return 0
    Dim resolvedType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel(translation, catalog, typeTokens(), 0, _
                         typeTokenCount - 1, resolvedType, _
                         C2FB_POINTER_MAPPING_PRESERVE, _
                         C2FB_TYPE_MAPPING_BODY, _
                         C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
    Dim targetRecord As String = CBodyRecordName( _
        translation, catalog, sourceType)
    Dim literalRecord As String
    If resolvedType.status = C2FB_TYPE_RESOLUTION_RESOLVED Then _
        literalRecord = CBodyRecordName( _
            translation, catalog, resolvedType.freeBasicType)
    If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
       resolvedType.pointerCount <> 0 OrElse _
       literalRecord = "" OrElse literalRecord <> targetRecord Then
        RecordSimpleBodyFailure( _
            context, "incompatible-compound-literal-assignment", _
            "compound literal type does not match destination " & targetName)
        Return 0
    End If

    Dim translatedInitializer As String
    Dim aggregateText As String = Mid( _
        initializerText, aggregateStart, position - aggregateStart)
    If TranslateSimpleRecordInitializer( _
        translation, catalog, aggregateText, sourceType, translatedInitializer, _
        context, callableNames(), callableCount, parameterNames(), _
        parameterAliases(), parameterTypes(), symbolCount) = 0 Then Return 0
    outputText = targetAlias & " = " & translatedInitializer
    Return -1
End Function

Private Function ParseSimpleAddressedCompoundLiteralValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH OrElse _
       parser.position > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, parser.position) <> Asc("&") Then Return 0

    Dim literalPosition As Long = parser.position + 1
    SkipCSpaces(parser.sourceText, literalPosition)
    If literalPosition > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, literalPosition) <> Asc("(") Then Return 0

    Dim typeStart As Long = literalPosition + 1
    If ScanSimpleExpressionGroup( _
        parser.sourceText, literalPosition, Asc("("), Asc(")")) = 0 Then Return 0
    Dim typeText As String = Trim(Mid( _
        parser.sourceText, typeStart, literalPosition - typeStart - 1))
    SkipCSpaces(parser.sourceText, literalPosition)
    If literalPosition > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, literalPosition) <> Asc("{") Then Return 0

    Dim aggregateStart As Long = literalPosition
    If ScanSimpleExpressionGroup( _
        parser.sourceText, literalPosition, Asc("{"), Asc("}")) = 0 Then Return 0
    Dim aggregateText As String = Mid( _
        parser.sourceText, aggregateStart, literalPosition - aggregateStart)
    parser.position = literalPosition

    If InStr(typeText, "[") <> 0 Then
        If parser.context <> 0 Then _
            RecordSimpleBodyFailure(parser.context[0], _
                "unsupported-addressed-array-compound-literal", _
                "address-of array compound literals are unsupported")
        Return 1
    End If

    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(typeText, typeTokens(), typeTokenCount)
    If typeTokenCount <= 0 Then Return 1
    Dim resolvedType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        parser.translation[0], parser.catalog[0], typeTokens(), 0, _
        typeTokenCount - 1, resolvedType, C2FB_POINTER_MAPPING_PRESERVE, _
        C2FB_TYPE_MAPPING_BODY, C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
    If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then
        If parser.context <> 0 Then _
            RecordSimpleBodyFailure(parser.context[0], _
                "unsupported-addressed-compound-literal-type", _
                "cannot resolve addressed compound literal type " & typeText)
        Return 1
    End If

    Dim freeBasicType As String = resolvedType.freeBasicType
    If resolvedType.isConst <> 0 AndAlso Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Mid(freeBasicType, 7)
    Dim recordName As String = CBodyRecordName( _
        parser.translation[0], parser.catalog[0], freeBasicType)
    Dim isRecord As Long = CInt(recordName <> "")
    Dim isPointer As Long = CInt(InStr(freeBasicType, " Ptr") <> 0)
    Dim isCallback As Long = CInt( _
        IsCBodyCallbackTypeInContext(parser.translation[0], freeBasicType) <> 0)
    If isRecord = 0 AndAlso isPointer = 0 AndAlso isCallback = 0 AndAlso _
       SimpleArithmeticKind(parser.catalog[0], freeBasicType) = 0 Then
        If parser.context <> 0 Then _
            RecordSimpleBodyFailure(parser.context[0], _
                "unsupported-addressed-compound-literal-type", _
                "addressed compound literal type has no supported storage: " & typeText)
        Return 1
    End If

    Dim pointerType As String = freeBasicType & " Ptr"
    If resolvedType.isConst <> 0 Then pointerType = "Const " & pointerType
    If parser.unevaluated <> 0 Then
        value.text = "CPtr(" & pointerType & ", 0)"
        value.typeName = pointerType
        value.layoutType = pointerType
        value.storageType = pointerType
        value.cRecord = recordName
        value.isLValue = 0
        value.isAddressAccessor = 0
        value.isReadOnly = resolvedType.isConst
        Return -1
    End If
    If parser.context = 0 Then Return 1

    Dim temporaryName As String = NewSimpleBodyTemporary( _
        parser.context[0], freeBasicType, "")
    If temporaryName = "" Then
        RecordSimpleBodyFailure(parser.context[0], _
            "compound-literal-workspace-limit", _
            "too many compound literal objects in this C procedure")
        Return 1
    End If

    Dim initializedValue As String
    Dim initializerPrelude As String
    If isRecord <> 0 Then
        If TranslateSimpleRecordInitializer( _
            parser.translation[0], parser.catalog[0], aggregateText, _
            freeBasicType, initializedValue, parser.context[0], _
            callableNames(), callableCount, parameterNames(), _
            parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 1
    Else
        Dim initializerBody As String = Trim(Mid( _
            aggregateText, 2, Len(aggregateText) - 2))
        If Right(initializerBody, 1) = "," Then _
            initializerBody = RTrim(Left(initializerBody, Len(initializerBody) - 1))
        If initializerBody = "" Then
            If isPointer <> 0 OrElse isCallback <> 0 Then
                initializedValue = "CPtr(" & freeBasicType & ", 0)"
            Else
                initializedValue = "Cast(" & freeBasicType & ", 0)"
            End If
        Else
            Dim initializerValues() As String
            Dim initializerCount As Long = 0
            If SplitSimpleCList( _
                initializerBody, initializerValues(), initializerCount) = 0 OrElse _
               initializerCount <> 1 Then
                RecordSimpleBodyFailure(parser.context[0], _
                    "unsupported-scalar-compound-literal-initializer", _
                    "scalar compound literal requires one initializer value")
                Return 1
            End If
            If TranslateSequencedExpression( _
                parser.translation[0], parser.catalog[0], _
                initializerValues(0), initializedValue, initializerPrelude, _
                parser.context[0], callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                parameterCount, freeBasicType) = 0 Then Return 1
        End If
    End If

    value.text = "CPtr(" & pointerType & ", @" & temporaryName & ")"
    value.typeName = pointerType
    value.layoutType = pointerType
    value.storageType = pointerType
    value.cRecord = recordName
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.isReadOnly = resolvedType.isConst
    value.prelude = initializerPrelude
    If value.prelude <> "" AndAlso Right(value.prelude, 1) <> Chr(10) Then _
        value.prelude &= Chr(10)
    value.prelude &= temporaryName & " = " & initializedValue & Chr(10)
    parser.hasRuntimeValue = -1
    Return -1
End Function

Private Function ParseSimpleRecordCompoundLiteralValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH OrElse _
       parser.position > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, parser.position) <> Asc("(") Then Return 0

    Dim literalPosition As Long = parser.position
    Dim typeStart As Long = literalPosition + 1
    If ScanSimpleExpressionGroup( _
        parser.sourceText, literalPosition, Asc("("), Asc(")")) = 0 Then _
        Return 0
    Dim typeText As String = Trim(Mid( _
        parser.sourceText, typeStart, literalPosition - typeStart - 1))

    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(typeText, typeTokens(), typeTokenCount)
    If typeTokenCount <= 0 Then Return 0
    Dim resolvedType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        parser.translation[0], parser.catalog[0], typeTokens(), 0, _
        typeTokenCount - 1, resolvedType, C2FB_POINTER_MAPPING_PRESERVE, _
        C2FB_TYPE_MAPPING_BODY, C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
    If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
       resolvedType.pointerCount <> 0 Then Return 0

    Dim freeBasicType As String = resolvedType.freeBasicType
    If resolvedType.isConst <> 0 AndAlso Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Mid(freeBasicType, 7)
    Dim recordName As String = CBodyRecordName( _
        parser.translation[0], parser.catalog[0], freeBasicType)
    If recordName = "" Then Return 0

    SkipCSpaces(parser.sourceText, literalPosition)
    If literalPosition > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, literalPosition) <> Asc("{") Then Return 0
    Dim aggregateStart As Long = literalPosition
    If ScanSimpleExpressionGroup( _
        parser.sourceText, literalPosition, Asc("{"), Asc("}")) = 0 Then Return 0
    Dim aggregateText As String = Mid( _
        parser.sourceText, aggregateStart, literalPosition - aggregateStart)
    parser.position = literalPosition

    value.text = "0"
    value.typeName = freeBasicType
    value.layoutType = freeBasicType
    value.storageType = freeBasicType
    value.cRecord = recordName
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.isReadOnly = resolvedType.isConst
    If parser.unevaluated <> 0 Then Return -1
    If parser.context = 0 Then Return 1

    ' A C block-scope compound literal is an addressable object whose storage
    ' lasts through the enclosing block. Hoisted storage gives the expression
    ' a stable lvalue while its initializer still runs at the expression site.
    Dim temporaryName As String = NewSimpleBodyTemporary( _
        parser.context[0], freeBasicType, "")
    If temporaryName = "" Then
        RecordSimpleBodyFailure(parser.context[0], _
            "compound-literal-workspace-limit", _
            "too many compound literal objects in this C procedure")
        Return 1
    End If

    Dim initializedValue As String
    Dim initializerPrelude As String
    If TranslateSimpleRecordInitializerWithPrelude( _
        parser.translation[0], parser.catalog[0], aggregateText, _
        freeBasicType, initializedValue, initializerPrelude, parser.context[0], _
        callableNames(), callableCount, parameterNames(), _
        parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 1

    value.text = temporaryName
    value.isLValue = -1
    value.prelude = initializerPrelude
    If value.prelude <> "" AndAlso Right(value.prelude, 1) <> Chr(10) Then _
        value.prelude &= Chr(10)
    value.prelude &= temporaryName & " = " & initializedValue & Chr(10)
    parser.hasRuntimeValue = -1
    Return -1
End Function

Private Function ParseSimpleArrayCompoundLiteralValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH OrElse _
       parser.position > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, parser.position) <> Asc("(") Then Return 0

    Dim literalPosition As Long = parser.position
    Dim typeStart As Long = literalPosition + 1
    If ScanSimpleExpressionGroup( _
        parser.sourceText, literalPosition, Asc("("), Asc(")")) = 0 Then Return 0
    Dim typeText As String = Trim(Mid( _
        parser.sourceText, typeStart, literalPosition - typeStart - 1))
    If InStr(typeText, "[") = 0 Then Return 0
    SkipCSpaces(parser.sourceText, literalPosition)
    If literalPosition > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, literalPosition) <> Asc("{") Then Return 0

    Dim aggregateStart As Long = literalPosition
    If ScanSimpleExpressionGroup( _
        parser.sourceText, literalPosition, Asc("{"), Asc("}")) = 0 Then Return 0
    Dim aggregateText As String = Mid( _
        parser.sourceText, aggregateStart, literalPosition - aggregateStart)
    parser.position = literalPosition
    If parser.unevaluated <> 0 Then
        If parser.context = 0 Then Return 1
        Dim pointerType As String
        Dim pointerExpression As String
        Dim outputPrelude As String
        Dim arrayCount As Long
        Dim unusedSymbolCount As Long = 0
        If LowerSimpleCompoundLiteralArrayValue( _
            parser.translation[0], parser.catalog[0], typeText, aggregateText, _
            "array compound literal sizeof operand", "", pointerType, _
            pointerExpression, outputPrelude, parser.context[0], _
            callableNames(), callableCount, parameterNames(), _
            parameterAliases(), parameterTypes(), unusedSymbolCount, _
            arrayCount, -1) = 0 Then Return 1

        value.text = pointerExpression
        value.typeName = pointerType
        value.layoutType = value.typeName
        value.storageType = value.typeName
        value.arrayCount = arrayCount
        value.arrayBound = Trim(Str(arrayCount)) & "ULL"
        value.arrayElementType = SimplePointeeType(pointerType)
        value.isLValue = -1
        value.isAddressAccessor = 0
        value.isReadOnly = CInt(Left(pointerType, 6) = "Const ")
        Return -1
    End If
    If parser.context = 0 Then Return 1

    Dim pointerType As String
    Dim pointerExpression As String
    Dim outputPrelude As String
    Dim arrayCount As Long
    If LowerSimpleCompoundLiteralArrayValue( _
        parser.translation[0], parser.catalog[0], typeText, aggregateText, _
        "array compound literal expression", "", pointerType, _
        pointerExpression, outputPrelude, parser.context[0], _
        callableNames(), callableCount, parameterNames(), _
        parameterAliases(), parameterTypes(), parameterCount, arrayCount) = 0 Then _
        Return 1

    value.text = pointerExpression
    value.typeName = pointerType
    value.layoutType = pointerType
    value.storageType = pointerType
    value.cRecord = CBodyRecordName( _
        parser.translation[0], parser.catalog[0], pointerType)
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.isReadOnly = CInt(Left(pointerType, 6) = "Const ")
    value.prelude = outputPrelude
    parser.hasRuntimeValue = -1
    Return -1
End Function

Private Function CompactSimpleAssertExpression(ByVal sourceText As String) As String
    Dim result As String
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    For position As Long = 1 To Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If quoteByte <> 0 Then
            result &= Chr(currentByte)
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
        ElseIf currentByte = Asc(Chr(34)) OrElse _
               currentByte = Asc("'") Then
            quoteByte = currentByte
            result &= Chr(currentByte)
        ElseIf IsSpaceByte(currentByte) = 0 Then
            result &= Chr(currentByte)
        End If
    Next
    Return result
End Function


Private Function TranslateSimpleGnuMemoryClobberStatement( _
    ByVal statementText As String, _
    ByRef outputText As String _
) As Long
    Dim compactText As String = CompactSimpleAssertExpression(Trim(statementText))
    If Right(compactText, 1) = ";" Then _
        compactText = Left(compactText, Len(compactText) - 1)

    ' This exact GNU form is a compiler barrier with no machine-code template.
    ' Empty FreeBASIC Asm blocks are discarded, so use nop. The FBC GCC and
    ' LLVM backends attach a memory clobber to inline assembly statements.
    Dim memoryBarrierSuffix As String = "(" & Chr(34) & Chr(34) & ":::" & _
                                        Chr(34) & "memory" & Chr(34) & ")"
    If Len(compactText) <= Len(memoryBarrierSuffix) Then Return 0
    If Right(compactText, Len(memoryBarrierSuffix)) <> memoryBarrierSuffix Then _
        Return 0

    Dim assemblerAndQualifier As String = Left( _
        compactText, Len(compactText) - Len(memoryBarrierSuffix))
    Select Case assemblerAndQualifier
    Case "asmvolatile", "asm__volatile", "asm__volatile__", _
         "__asmvolatile", "__asm__volatile", "__asm__volatile__", _
         "__asm____volatile", "__asm____volatile__"
        outputText = "' Preserve the GNU compiler memory barrier." & Chr(10) & _
                     "Asm" & Chr(10) & _
                     "    nop" & Chr(10) & _
                     "End Asm"
        Return -1
    End Select
    Return 0
End Function


Private Function RewriteSimpleAssertFunctionTokens( _
    ByVal sourceText As String, ByVal functionName As String _
) As String
    Dim result As String
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    Dim position As Long = 1
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If quoteByte <> 0 Then
            result &= Chr(currentByte)
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
        ElseIf currentByte = Asc(Chr(34)) OrElse _
               currentByte = Asc("'") Then
            quoteByte = currentByte
            result &= Chr(currentByte)
            position += 1
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceText) AndAlso _
                  IsIdentifierPart(Asc(sourceText, position)) <> 0
                position += 1
            Wend
            Dim token As String = Mid(sourceText, tokenStart, position - tokenStart)
            Select Case token
            Case "__extension__"
                ' GCC uses this token only to suppress diagnostics.
            Case "__PRETTY_FUNCTION__", "__func__"
                result &= Chr(34) & functionName & Chr(34)
            Case Else
                result &= token
            End Select
        Else
            result &= Chr(currentByte)
            position += 1
        End If
    Wend
    Return result
End Function


Private Function RejectSimpleAssertExpansion( _
    ByRef context As SimpleBodyContext, ByVal message As String _
) As Long
    RecordSimpleBodyFailure( _
        context, "unsupported-assert-expansion", message)
    Return 0
End Function


Private Function TranslateSimpleAssertExpansionStatement( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, ByRef outputText As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByRef symbolCount As Long, _
    ByRef statementTerminates As Long _
) As Long
    outputText = ""
    statementTerminates = 0
    statementText = Trim(statementText)
    If Right(statementText, 1) = ";" Then _
        statementText = RTrim(Left(statementText, Len(statementText) - 1))
    Dim argumentMarker As Long = InStr(statementText, "__assert_single_arg")
    Dim extensionMarker As Long = InStr(statementText, "__extension__")
    If argumentMarker = 0 OrElse extensionMarker = 0 OrElse _
       extensionMarker < argumentMarker Then Return 0

    Dim argumentOpen As Long = argumentMarker + Len("__assert_single_arg")
    SkipCSpaces(statementText, argumentOpen)
    If argumentOpen > Len(statementText) OrElse _
       Asc(statementText, argumentOpen) <> Asc("(") Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert expansion has no single-argument check")
    Dim argumentEnd As Long = argumentOpen
    If ScanSimpleExpressionGroup( _
        statementText, argumentEnd, Asc("("), Asc(")")) = 0 Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert single-argument check is malformed")
    Dim probedExpression As String = Trim(Mid( _
        statementText, argumentOpen + 1, argumentEnd - argumentOpen - 2))

    Dim blockOpen As Long = InStr(extensionMarker, statementText, "{")
    If blockOpen = 0 Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert extension block is missing")
    Dim ifPosition As Long = InStr(blockOpen, statementText, "if")
    If ifPosition = 0 OrElse _
       (ifPosition > 1 AndAlso _
        IsIdentifierPart(Asc(statementText, ifPosition - 1)) <> 0) OrElse _
       (ifPosition + 2 <= Len(statementText) AndAlso _
        IsIdentifierPart(Asc(statementText, ifPosition + 2)) <> 0) Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert expansion has no if statement")
    Dim conditionOpen As Long = ifPosition + Len("if")
    SkipCSpaces(statementText, conditionOpen)
    If conditionOpen > Len(statementText) OrElse _
       Asc(statementText, conditionOpen) <> Asc("(") Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert if condition is not parenthesized")
    Dim conditionEnd As Long = conditionOpen
    If ScanSimpleExpressionGroup( _
        statementText, conditionEnd, Asc("("), Asc(")")) = 0 Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert if condition is malformed")
    Dim conditionText As String = Trim(Mid( _
        statementText, conditionOpen + 1, conditionEnd - conditionOpen - 2))
    If conditionText = "" OrElse _
       CompactSimpleAssertExpression(probedExpression) <> _
       CompactSimpleAssertExpression(conditionText) Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert runtime condition does not match its compile-time check")

    Dim position As Long = conditionEnd
    SkipCSpaces(statementText, position)
    If position > Len(statementText) OrElse _
       Asc(statementText, position) <> Asc(";") Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert if statement has no empty then branch")
    position += 1
    SkipCSpaces(statementText, position)
    If Mid(statementText, position, Len("else")) <> "else" OrElse _
       (position + Len("else") <= Len(statementText) AndAlso _
        IsIdentifierPart(Asc(statementText, position + Len("else"))) <> 0) Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert if statement has no else branch")
    position += Len("else")
    SkipCSpaces(statementText, position)
    If Mid(statementText, position, Len("__assert_fail")) <> "__assert_fail" Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert else branch does not call __assert_fail")
    Dim failureStart As Long = position
    position += Len("__assert_fail")
    SkipCSpaces(statementText, position)
    If position > Len(statementText) OrElse _
       Asc(statementText, position) <> Asc("(") Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert failure handler has no argument list")
    Dim failureEnd As Long = position
    If ScanSimpleExpressionGroup( _
        statementText, failureEnd, Asc("("), Asc(")")) = 0 Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert failure argument list is malformed")

    position = failureEnd
    SkipCSpaces(statementText, position)
    If position <= Len(statementText) AndAlso _
       Asc(statementText, position) = Asc(";") Then position += 1
    SkipCSpaces(statementText, position)
    If position > Len(statementText) OrElse _
       Asc(statementText, position) <> Asc("}") Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert extension block does not close")
    position += 1
    SkipCSpaces(statementText, position)
    If position > Len(statementText) OrElse _
       Asc(statementText, position) <> Asc(")") Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert extension parenthesis does not close")
    position += 1
    SkipCSpaces(statementText, position)
    If position > Len(statementText) OrElse _
       Asc(statementText, position) <> Asc(")") Then _
        Return RejectSimpleAssertExpansion( _
            context, "assert expression parenthesis does not close")
    position += 1
    SkipCSpaces(statementText, position)
    If position <= Len(statementText) Then Return 0

    Dim translatedCondition As String
    Dim conditionPrelude As String
    If TranslateSequencedExpression( _
        translation, catalog, conditionText, translatedCondition, _
        conditionPrelude, context, callableNames(), callableCount, _
        parameterNames(), parameterAliases(), parameterTypes(), _
        symbolCount) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-assert-condition", _
            "unsupported C assert condition: " & Left(conditionText, 160))
        Return 0
    End If

    Dim failureCall As String = Mid( _
        statementText, failureStart, failureEnd - failureStart)
    failureCall = RewriteSimpleAssertFunctionTokens( _
        failureCall, context.functionName)
    ' The assertion handler returns void. Parse it as a statement expression
    ' so the value-required sequenced-expression path does not reject the call.
    Dim failureParser As SimpleExpressionParser
    failureParser.sourceText = failureCall
    failureParser.position = 1
    failureParser.translation = @translation
    failureParser.catalog = @catalog
    failureParser.context = @context
    Dim failureValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        failureParser, failureValue, 1, 0, callableNames(), callableCount, _
        parameterNames(), parameterAliases(), parameterTypes(), symbolCount) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-assert-failure-call", _
            "assert failure call parser stopped at byte " & _
            Trim(Str(failureParser.position)) & ": " & _
            Left(Mid(failureParser.sourceText, failureParser.position), 100))
        Return 0
    End If
    SkipCSpaces(failureParser.sourceText, failureParser.position)
    If failureParser.position <= Len(failureCall) OrElse _
       failureValue.typeName <> "void" Then
        RecordSimpleBodyFailure( _
            context, "unsupported-assert-failure-call", _
            "assert failure call has an unsupported return type or suffix: " & _
            failureValue.typeName & " " & _
            Left(Mid(failureParser.sourceText, failureParser.position), 80))
        Return 0
    End If

    outputText = RTrim(conditionPrelude, Any Chr(10))
    If outputText <> "" Then outputText &= Chr(10)
    outputText &= "If (" & translatedCondition & " = 0) Then" & Chr(10)
    If failureValue.prelude <> "" Then
        outputText &= IndentSimpleBodyText( _
            RTrim(failureValue.prelude, Any Chr(10)), "    ") & Chr(10)
    End If
    outputText &= "    " & failureValue.text & Chr(10) & "End If"
    Dim conditionValue As Long
    If SimpleCConditionConstantValue( _
        translation, conditionText, parameterNames(), parameterAliases(), _
        symbolCount, conditionValue) <> 0 AndAlso conditionValue = 0 AndAlso _
       SimpleCStatementAlwaysTerminates( _
        translation, failureCall, parameterNames(), parameterAliases(), _
        symbolCount) <> 0 Then
        statementTerminates = -1
    End If
    Return -1
End Function


Private Function TranslateSimpleAssertExpansionValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If parser.context = 0 OrElse parser.translation = 0 OrElse _
       parser.catalog = 0 OrElse parser.position > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, parser.position) <> Asc("(") Then Return 0

    Dim groupEnd As Long = parser.position
    If ScanSimpleExpressionGroup( _
        parser.sourceText, groupEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim groupText As String = Mid( _
        parser.sourceText, parser.position, groupEnd - parser.position)
    Dim argumentOffset As Long = InStr(groupText, "__assert_single_arg")
    Dim extensionOffset As Long = InStr(groupText, "__extension__")
    If argumentOffset = 0 OrElse extensionOffset < argumentOffset Then Return 0

    ' The assert macro is nested within a ternary branch that may have its own
    ' parentheses and a comma-expression suffix. Find the nearest containing
    ' group so the suffix remains in the expression parser.
    Dim argumentPosition As Long = parser.position + argumentOffset - 1
    Dim extensionPosition As Long = parser.position + extensionOffset - 1
    Dim assertStart As Long = 0
    Dim assertEnd As Long = 0
    For candidate As Long = argumentPosition - 1 To parser.position Step -1
        If Asc(parser.sourceText, candidate) <> Asc("(") Then Continue For
        Dim candidateEnd As Long = candidate
        If ScanSimpleExpressionGroup( _
            parser.sourceText, candidateEnd, Asc("("), Asc(")")) <> 0 AndAlso _
           candidateEnd > extensionPosition Then
            assertStart = candidate
            assertEnd = candidateEnd
            Exit For
        End If
    Next
    If assertStart <> parser.position OrElse assertEnd <= assertStart Then Return 0

    Dim assertionText As String = Mid( _
        parser.sourceText, assertStart, assertEnd - assertStart)
    Dim assertionPrelude As String
    Dim assertionTerminates As Long = 0
    Dim symbolCount As Long = parameterCount
    If TranslateSimpleAssertExpansionStatement( _
        parser.translation[0], parser.catalog[0], assertionText, _
        assertionPrelude, parser.context[0], callableNames(), callableCount, _
        parameterNames(), parameterAliases(), parameterTypes(), _
        symbolCount, assertionTerminates) = 0 Then Return 0

    ' Keep the failure check as a prelude on this void value. Conditional
    ' lowering then evaluates it only when C selects this expression branch.
    value.text = ""
    value.typeName = "void"
    value.layoutType = ""
    value.storageType = ""
    value.cRecord = ""
    value.isLValue = 0
    value.isWholeCall = 0
    value.isFunctionDesignator = 0
    value.prelude = assertionPrelude & Chr(10)
    parser.position = assertEnd
    Return -1
End Function


Private Function StripSimpleOuterParentheses( _
    ByVal sourceText As String _
) As String
    sourceText = Trim(sourceText)
    While Len(sourceText) >= 2 AndAlso Left(sourceText, 1) = "("
        Dim position As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceText, position, Asc("("), Asc(")")) = 0 OrElse _
           position <> Len(sourceText) + 1 Then Exit While
        sourceText = Trim(Mid(sourceText, 2, Len(sourceText) - 2))
    Wend
    Return sourceText
End Function


Private Function FindSimpleConditionalParts( _
    ByVal sourceText As String, _
    ByRef questionPosition As Long, _
    ByRef colonPosition As Long _
) As Long
    Dim parentheses As Long = 0
    Dim brackets As Long = 0
    Dim braces As Long = 0
    Dim nestedConditionals As Long = 0
    Dim quoteByte As Long = 0
    questionPosition = 0
    colonPosition = 0

    Dim position As Long = 1
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If quoteByte <> 0 Then
            If currentByte = Asc(Chr(92)) Then
                position += 2
                Continue While
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
        ElseIf currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
        ElseIf currentByte = Asc("(") Then
            parentheses += 1
        ElseIf currentByte = Asc(")") Then
            If parentheses > 0 Then parentheses -= 1
        ElseIf currentByte = Asc("[") Then
            brackets += 1
        ElseIf currentByte = Asc("]") Then
            If brackets > 0 Then brackets -= 1
        ElseIf currentByte = Asc("{") Then
            braces += 1
        ElseIf currentByte = Asc("}") Then
            If braces > 0 Then braces -= 1
        ElseIf parentheses = 0 AndAlso brackets = 0 AndAlso braces = 0 Then
            If currentByte = Asc("?") Then
                If questionPosition = 0 Then
                    questionPosition = position
                Else
                    nestedConditionals += 1
                End If
            ElseIf currentByte = Asc(":") AndAlso questionPosition <> 0 Then
                If nestedConditionals = 0 Then
                    colonPosition = position
                    Return -1
                End If
                nestedConditionals -= 1
            End If
        End If
        position += 1
    Wend
    Return 0
End Function


Private Function TranslateSimpleUnreachableAssumption( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, ByRef outputText As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    outputText = ""
    statementText = Trim(statementText)
    If Right(statementText, 1) = ";" Then _
        statementText = RTrim(Left(statementText, Len(statementText) - 1))

    Dim directText As String = CompactSimpleAssertExpression( _
        StripSimpleOuterParentheses(statementText))
    If directText = "__builtin_unreachable()" OrElse _
       directText = "__builtin_trap()" Then
        outputText = "Error 5"
        Return -1
    End If

    ' verify.h expands assume(R) to a void conditional whose failing branch
    ' is unreachable. Reaching that branch is undefined in C, so terminate
    ' translated code there instead of silently discarding the assumption.
    Dim conditionalText As String = StripSimpleOuterParentheses(statementText)
    Dim questionPosition As Long
    Dim colonPosition As Long
    If FindSimpleConditionalParts( _
        conditionalText, questionPosition, colonPosition) = 0 Then Return 0

    Dim conditionText As String = Trim(Left(conditionalText, questionPosition - 1))
    Dim trueText As String = Trim(Mid( _
        conditionalText, questionPosition + 1, _
        colonPosition - questionPosition - 1))
    Dim falseText As String = Trim(Mid(conditionalText, colonPosition + 1))
    Dim compactTrue As String = CompactSimpleAssertExpression( _
        StripSimpleOuterParentheses(trueText))
    Dim compactFalse As String = CompactSimpleAssertExpression( _
        StripSimpleOuterParentheses(falseText))
    Dim unreachableWhenTrue As Long
    Select Case compactTrue
    Case "(void)0"
        If compactFalse = "__builtin_unreachable()" OrElse _
           compactFalse = "__builtin_trap()" Then
            unreachableWhenTrue = 0
        Else
            Return 0
        End If
    Case "__builtin_unreachable()", "__builtin_trap()"
        If compactFalse <> "(void)0" Then Return 0
        unreachableWhenTrue = -1
    Case Else
        Return 0
    End Select

    Dim parser As SimpleExpressionParser
    parser.sourceText = conditionText
    parser.position = 1
    parser.translation = @translation
    parser.catalog = @catalog
    parser.context = @context
    Dim conditionValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        parser, conditionValue, 1, 0, callableNames(), callableCount, _
        parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-assumption-condition", _
            "could not translate unreachable-assumption condition: " & _
            Left(conditionText, 160))
        Return 0
    End If
    SkipCSpaces(parser.sourceText, parser.position)
    ' GNU statement-expression lowering can change the parsed source length.
    If parser.position <= Len(parser.sourceText) Then
        RecordSimpleBodyFailure( _
            context, "unsupported-assumption-condition", _
            "assumption condition has an unsupported suffix: " & _
            Left(Mid(parser.sourceText, parser.position), 120))
        Return 0
    End If

    Dim truthCondition As String = SimpleScalarTruthCondition( _
        translation, catalog, conditionValue)
    If truthCondition = "" Then
        RecordSimpleBodyFailure( _
            context, "unsupported-assumption-condition", _
            "assumption condition is not a supported scalar: " & _
            Left(conditionText, 160))
        Return 0
    End If
    outputText = RTrim(conditionValue.prelude, Any Chr(10))
    If outputText <> "" Then outputText &= Chr(10)
    If unreachableWhenTrue <> 0 Then
        outputText &= "If (" & truthCondition & ") <> 0 Then Error 5"
    Else
        outputText &= "If (" & truthCondition & ") = 0 Then Error 5"
    End If
    Return -1
End Function


Private Function TranslateSimpleAssignmentStatement( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, ByRef outputText As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal symbolCount As Long, _
    ByRef statementTerminates As Long _
) As Long
    outputText = ""
    statementTerminates = 0
    Dim text As String = Trim(statementText)
    If text = "" Then
        outputText = "' empty C statement"
        Return -1
    End If
    If TranslateSimpleAssertExpansionStatement( _
        translation, catalog, text, outputText, context, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        symbolCount, statementTerminates) <> 0 Then Return -1
    If context.failureMessage <> "" Then Return 0
    If TranslateSimpleUnreachableAssumption( _
        translation, catalog, text, outputText, context, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        symbolCount) <> 0 Then Return -1
    If context.failureMessage <> "" Then Return 0
    Dim compactText As String = ""
    For textIndex As Long = 1 To Len(text)
        If IsSpaceByte(Asc(text, textIndex)) = 0 Then _
            compactText &= Mid(text, textIndex, 1)
    Next
    If context.functionName = "openDatabase" AndAlso _
       compactText = "db->aDb=db->aDbStatic" Then
        ' The port keeps Db slots inline in sqlite3.aDb. The C assignment
        ' selects its static backing array, which is already the only storage
        ' in this connection layout.
        outputText = "' C database slots are already stored inline"
        Return -1
    End If
    If TranslateSimpleCompoundLiteralAssignment( _
        translation, catalog, text, outputText, context, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        symbolCount) <> 0 Then Return -1
    Dim normalizedCountof As String
    If StripGnulibCountofArrayTypeCheck(text, normalizedCountof) <> 0 Then _
        text = normalizedCountof
    Dim parser As SimpleExpressionParser
    parser.sourceText = text
    parser.position = 1
    parser.translation = @translation
    parser.catalog = @catalog
    parser.context = @context
    Dim value As SimpleExpressionValue
    If ParseSimpleExpressionValue(parser, value, 1, 0, callableNames(), callableCount, _
                                  parameterNames(), parameterAliases(), parameterTypes(), symbolCount) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-assignment-expression", _
            "assignment parser stopped at byte " & Trim(Str(parser.position)) & _
                " (" & Left(text, 120) & "): " & _
                Left(Mid(parser.sourceText, parser.position), 80))
        Return 0
    End If
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position <= Len(parser.sourceText) Then
        RecordSimpleBodyFailure( _
            context, "unsupported-assignment-suffix", _
            "assignment parser left an unsupported suffix at byte " & _
            Trim(Str(parser.position)) & " (" & Left(text, 120) & "): " & _
            Left(Mid(parser.sourceText, parser.position), 80))
        Return 0
    End If
    If DiscardSimpleValue(parser, value) = 0 Then
        RecordSimpleBodyFailure( _
            context, "assignment-value-not-preserved", _
            "could not preserve assignment value: " & Left(statementText, 120))
        Return 0
    End If
    outputText = RTrim(value.prelude, Any Chr(10))
    If outputText = "" Then outputText = "' discarded C expression"
    Return -1
End Function

Private Function SimpleCConditionConstantValue( _
    ByRef translation As C2fbTranslationContext, _
    ByVal conditionText As String, _
    parameterNames() As String, parameterAliases() As String, _
    ByVal parameterCount As Long, ByRef conditionValue As Long _
) As Long
    conditionText = Trim(conditionText)
    If conditionText = "true" OrElse conditionText = "false" Then
        If ParameterAlias( _
            parameterNames(), parameterAliases(), parameterCount, conditionText) <> "" OrElse _
           CBodyExternalObjectIndex(translation, conditionText) >= 0 OrElse _
           CBodyProcedureIndex(translation, conditionText) >= 0 Then Return 0
        conditionValue = CInt(conditionText = "true")
        Return -1
    End If
    If EvaluateSimpleArrayBound( _
        conditionText, conditionValue, MAX_GENERIC_ARRAY_COUNT, -1) <> 0 Then _
        Return -1
    If EvaluateGenericBodyArrayBound( _
        translation, conditionText, conditionValue, _
        MAX_GENERIC_ARRAY_COUNT) <> 0 Then Return -1
    Return 0
End Function

Private Function SimpleCConditionAlwaysTrue( _
    ByRef translation As C2fbTranslationContext, _
    ByVal conditionText As String, _
    parameterNames() As String, parameterAliases() As String, _
    ByVal parameterCount As Long _
) As Long
    Dim conditionValue As Long
    If SimpleCConditionConstantValue( _
        translation, conditionText, parameterNames(), parameterAliases(), _
        parameterCount, conditionValue) = 0 Then Return 0
    Return CInt(conditionValue <> 0)
End Function

Private Function SimpleBlockContainsSwitchLabel( _
    ByVal sourceText As String, ByVal openingPosition As Long _
) As Long
    If openingPosition < 1 OrElse openingPosition > Len(sourceText) OrElse _
       Asc(sourceText, openingPosition) <> Asc("{") Then Return 0

    Dim braceDepth As Long = 1
    Dim parenthesisDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    Dim lineComment As Long = 0
    Dim blockComment As Long = 0
    Dim position As Long = openingPosition + 1
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If lineComment <> 0 Then
            If currentByte = Asc(Chr(10)) Then lineComment = 0
        ElseIf blockComment <> 0 Then
            If currentByte = Asc("*") AndAlso _
               Mid(sourceText, position + 1, 1) = "/" Then
                blockComment = 0
                position += 1
            End If
        ElseIf quoteByte <> 0 Then
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
        ElseIf currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quoteByte = currentByte
        ElseIf currentByte = Asc("/") AndAlso _
               Mid(sourceText, position + 1, 1) = "/" Then
            lineComment = -1
            position += 1
        ElseIf currentByte = Asc("/") AndAlso _
               Mid(sourceText, position + 1, 1) = "*" Then
            blockComment = -1
            position += 1
        ElseIf currentByte = Asc("{") Then
            braceDepth += 1
        ElseIf currentByte = Asc("}") Then
            braceDepth -= 1
            If braceDepth = 0 Then Return 0
        ElseIf currentByte = Asc("(") Then
            parenthesisDepth += 1
        ElseIf currentByte = Asc(")") Then
            If parenthesisDepth > 0 Then parenthesisDepth -= 1
        ' _Generic associations use case/default spellings inside parentheses.
        ' Those are not labels that the surrounding switch must hoist.
        ElseIf braceDepth = 1 AndAlso parenthesisDepth = 0 AndAlso _
               (currentByte = Asc("c") OrElse currentByte = Asc("d")) AndAlso _
               IsIdentifierPart(Asc(sourceText, position - 1)) = 0 AndAlso _
               IsSimpleSwitchLabel(sourceText, position) <> 0 Then
            ' A switch label must begin at a C token boundary. Otherwise a
            ' name such as space_output_delimiter_default looks like a label.
            Return -1
        End If
        position += 1
    Wend
    Return 0
End Function


Private Function ParseSimpleCBlock( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef sourceText As String, _
    ByRef position As Long, _
    ByRef outputText As String, _
    ByVal indentText As String, _
    ByVal returnType As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, _
    ByVal callableCount As Long, _
    parameterNames() As String, _
    parameterAliases() As String, _
    parameterTypes() As String, _
    ByRef symbolCount As Long, _
    locals() As SimpleLocalVariable, _
    ByRef localCount As Long, _
    ByRef terminatesPaths As Long _
) As Long
    outputText = ""
    terminatesPaths = 0
    SkipCSpaces(sourceText, position)
    If position > Len(sourceText) OrElse Asc(sourceText, position) <> Asc("{") Then Return 0
    If context.frameCount > 0 AndAlso _
       context.frames(context.frameCount - 1).isSwitch <> 0 AndAlso _
       SimpleBlockContainsSwitchLabel(sourceText, position) <> 0 Then
        position += 1
        If PushSimpleBodyScope(context, symbolCount, localCount) = 0 Then Return 0
        context.frames(context.frameCount - 1).nestedCaseBlockDepth += 1
        outputText = indentText & "' C nested switch-case scope"
        Return -1
    End If
    position += 1
    Dim statementCount As Long = 0
    If PushSimpleBodyScope(context, symbolCount, localCount) = 0 Then Return 0

    While position <= Len(sourceText)
        SkipCSpaces(sourceText, position)
        If position > Len(sourceText) Then Return 0
        If Asc(sourceText, position) = Asc("}") Then
            position += 1
            If statementCount = 0 Then outputText = indentText & "' empty C block"
            PopSimpleBodyScope(context, symbolCount, localCount)
            Return -1
        End If

        Dim statementText As String = ""
        Dim statementTerminates As Long = 0
        If ParseSimpleCStatement(translation, catalog, sourceText, position, statementText, indentText, returnType, context, _
                                 callableNames(), callableCount, parameterNames(), _
                                 parameterAliases(), parameterTypes(), symbolCount, locals(), localCount, _
                                 statementTerminates) = 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-block-statement", _
                "unsupported block statement: " & Left(Mid(sourceText, position), 240))
            Return 0
        End If
        outputText &= IIf(statementCount = 0, "", Chr(10)) & statementText
        statementCount += 1
        terminatesPaths = statementTerminates
    Wend
    Return 0
End Function

Private Function ParseSimpleFallthroughAnnotation( _
    ByRef sourceText As String, ByRef position As Long, _
    ByRef outputText As String, ByVal indentText As String _
) As Long
    Dim parsePosition As Long = position
    SkipCSpaces(sourceText, parsePosition)
    Dim attributeText As String
    If Mid(sourceText, parsePosition, 2) = "[[" Then
        ' GCC preprocessing can normalize this GNU attribute to C23 spelling.
        Dim attributeStart As Long = parsePosition + 2
        Dim attributeEnd As Long = InStr(attributeStart, sourceText, "]]")
        If attributeEnd = 0 Then Return 0
        For i As Long = attributeStart To attributeEnd - 1
            If IsSpaceByte(Asc(sourceText, i)) = 0 Then _
                attributeText &= LCase(Mid(sourceText, i, 1))
        Next
        Select Case attributeText
        Case "fallthrough", "__fallthrough__", _
             "gnu::fallthrough", "gnu::__fallthrough__", _
             "__gnu__::fallthrough", "__gnu__::__fallthrough__"
            parsePosition = attributeEnd + 2
        Case Else
            Return 0
        End Select
    Else
        If Mid(sourceText, parsePosition, 13) <> "__attribute__" Then Return 0
        If parsePosition + 13 <= Len(sourceText) AndAlso _
           IsIdentifierPart(Asc(sourceText, parsePosition + 13)) <> 0 Then Return 0

        parsePosition += 13
        SkipCSpaces(sourceText, parsePosition)
        If parsePosition > Len(sourceText) OrElse _
           Asc(sourceText, parsePosition) <> Asc("(") Then Return 0
        Dim attributeStart As Long = parsePosition + 1
        If ScanSimpleExpressionGroup( _
            sourceText, parsePosition, Asc("("), Asc(")")) = 0 Then Return 0

        For i As Long = attributeStart To parsePosition - 2
            If IsSpaceByte(Asc(sourceText, i)) = 0 Then _
                attributeText &= LCase(Mid(sourceText, i, 1))
        Next
        If attributeText <> "(fallthrough)" AndAlso _
           attributeText <> "(__fallthrough__)" Then Return 0
    End If

    SkipCSpaces(sourceText, parsePosition)
    If parsePosition > Len(sourceText) OrElse _
       Asc(sourceText, parsePosition) <> Asc(";") Then Return 0
    parsePosition += 1
    position = parsePosition
    outputText = indentText & "' C switch fallthrough annotation"
    Return -1
End Function

Private Function IsUnusedLocalRecordDefinition( _
    ByVal statementText As String, ByVal remainingSource As String _
) As Long
    statementText = Trim(statementText)
    If Right(statementText, 1) = ";" Then _
        statementText = RTrim(Left(statementText, Len(statementText) - 1))
    Dim openingBrace As Long = InStr(statementText, "{")
    If openingBrace = 0 OrElse _
       Trim(Mid(statementText, openingBrace)) = "" Then Return 0

    Dim prefix As String = Trim(Left(statementText, openingBrace - 1))
    Dim recordTag As String
    Dim isTypedef As Long
    Dim isPacked As Long
    Dim recordKind As C2fbRecordKind = C2fbRecordKindFromPrefix( _
        prefix, recordTag, isTypedef, isPacked)
    If recordKind <> C2FB_RECORD_STRUCT AndAlso _
       recordKind <> C2FB_RECORD_UNION Then Return 0

    Dim prefixTokens() As String
    Dim prefixTokenCount As Long
    TokenizeCDeclaration(prefix, prefixTokens(), prefixTokenCount)
    Dim typeTokenIndex As Long = -1
    For tokenIndex As Long = 0 To prefixTokenCount - 1
        If prefixTokens(tokenIndex) = "struct" OrElse _
           prefixTokens(tokenIndex) = "union" Then
            typeTokenIndex = tokenIndex
            Exit For
        End If
    Next
    If typeTokenIndex < 0 Then Return 0
    For tokenIndex As Long = 0 To typeTokenIndex - 1
        Select Case prefixTokens(tokenIndex)
        Case "const", "volatile", "restrict", "__restrict", _
             "__restrict__", "static", "extern", "register", "inline", _
             "__inline", "__inline__"
            Continue For
        Case Else
            Return 0
        End Select
    Next
    If recordTag <> "" Then
        If typeTokenIndex + 2 <> prefixTokenCount OrElse _
           prefixTokens(typeTokenIndex + 1) <> recordTag Then Return 0
    ElseIf typeTokenIndex + 1 <> prefixTokenCount Then
        Return 0
    End If

    Dim closingPosition As Long = openingBrace
    If ScanSimpleExpressionGroup( _
        statementText, closingPosition, Asc("{"), Asc("}")) = 0 OrElse _
       Trim(Mid(statementText, closingPosition)) <> "" Then Return 0
    If recordTag <> "" AndAlso _
       GenericLastIdentifierPosition(remainingSource, recordTag) <> 0 Then Return 0
    Return -1
End Function

Private Function TranslateSimpleLocalRecordTypeDefinition( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, _
    ByRef outputText As String, _
    ByRef context As SimpleBodyContext, _
    ByRef localRecordTag As String, _
    ByRef trailingDeclaration As String _
) As Long
    localRecordTag = ""
    trailingDeclaration = ""
    statementText = Trim(statementText)
    If Right(statementText, 1) = ";" Then _
        statementText = RTrim(Left(statementText, Len(statementText) - 1))
    Dim openingBrace As Long = InStr(statementText, "{")
    If openingBrace = 0 Then Return 0
    Dim prefix As String = Trim(Left(statementText, openingBrace - 1))
    Dim recordTag As String
    Dim isTypedef As Long
    Dim isPacked As Long
    If C2fbRecordKindFromPrefix( _
        prefix, recordTag, isTypedef, isPacked) <> C2FB_RECORD_STRUCT OrElse _
       recordTag = "" OrElse isTypedef <> 0 Then Return 0

    Dim prefixTokens() As String
    Dim prefixTokenCount As Long
    TokenizeCDeclaration(prefix, prefixTokens(), prefixTokenCount)
    Dim typeTokenIndex As Long = -1
    For tokenIndex As Long = 0 To prefixTokenCount - 1
        If prefixTokens(tokenIndex) = "struct" Then
            typeTokenIndex = tokenIndex
            Exit For
        End If
    Next
    If typeTokenIndex < 0 OrElse typeTokenIndex + 2 <> prefixTokenCount OrElse _
       prefixTokens(typeTokenIndex + 1) <> recordTag Then Return 0
    For tokenIndex As Long = 0 To typeTokenIndex - 1
        Select Case prefixTokens(tokenIndex)
        Case "const", "volatile", "restrict", "__restrict", _
             "__restrict__", "static", "extern", "register", "inline", _
             "__inline", "__inline__"
            Continue For
        Case Else
            Return 0
        End Select
    Next

    Dim recordEnd As Long = openingBrace
    If ScanSimpleExpressionGroup( _
        statementText, recordEnd, Asc("{"), Asc("}")) = 0 Then Return 0
    trailingDeclaration = Trim(Mid(statementText, recordEnd))
    Dim recordBody As String = Mid( _
        statementText, openingBrace + 1, recordEnd - openingBrace - 2)
    Dim generatedRecordName As String
    If RegisterCBodyAnonymousRecord( _
        translation, catalog, recordBody, generatedRecordName, _
        C2FB_RECORD_STRUCT, "c2fb_local_record_", 0, recordTag) = 0 Then _
        Return 0
    If RegisterSimpleBodyLocalType( _
        context, recordTag, generatedRecordName) = 0 Then
        RecordSimpleBodyFailure( _
            context, "duplicate-local-record-tag", _
            "duplicate block-local C record tag: " & recordTag)
        Return 0
    End If
    localRecordTag = recordTag
    outputText = "' C block-local record type declaration"
    Return -1
End Function

Private Function TranslateSimpleLocalTypeTypedef( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, _
    ByRef outputText As String, _
    ByRef context As SimpleBodyContext _
) As Long
    statementText = Trim(statementText)
    If Right(statementText, 1) = ";" Then _
        statementText = RTrim(Left(statementText, Len(statementText) - 1))
    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(statementText, typeTokens(), typeTokenCount)
    If typeTokenCount < 3 OrElse typeTokens(0) <> "typedef" Then Return 0
    Dim aliasIndex As Long = typeTokenCount - 1
    If IsIdentifierToken(typeTokens(aliasIndex)) = 0 Then Return 0
    Dim aliasName As String = typeTokens(aliasIndex)

    If typeTokenCount = 4 AndAlso _
       (typeTokens(1) = "struct" OrElse typeTokens(1) = "union") AndAlso _
       IsIdentifierToken(typeTokens(2)) <> 0 Then
        Dim freeBasicType As String = SimpleBodyLocalType( _
            context, typeTokens(2))
        If freeBasicType = "" Then _
            freeBasicType = MappedFbBodyRecord( _
                translation, catalog, typeTokens(2))
        If freeBasicType = "" OrElse _
           RegisterSimpleBodyLocalType( _
               context, typeTokens(3), freeBasicType) = 0 Then Return 0
        outputText = "' C block-local record typedef"
        Return -1
    End If

    Dim baseTokenCount As Long = aliasIndex - 1
    If baseTokenCount < 1 Then Return 0
    Dim baseTokens() As String
    ReDim baseTokens(0 To baseTokenCount - 1)
    For typeIndex As Long = 0 To baseTokenCount - 1
        If typeTokens(typeIndex + 1) = "*" OrElse _
           typeTokens(typeIndex + 1) = "[" OrElse _
           typeTokens(typeIndex + 1) = "(" OrElse _
           typeTokens(typeIndex + 1) = ")" OrElse _
           typeTokens(typeIndex + 1) = "struct" OrElse _
           typeTokens(typeIndex + 1) = "union" OrElse _
           typeTokens(typeIndex + 1) = "enum" Then Return 0
        baseTokens(typeIndex) = typeTokens(typeIndex + 1)
    Next

    Dim resolvedType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        translation, catalog, baseTokens(), 0, baseTokenCount - 1, _
        resolvedType)
    If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
       resolvedType.freeBasicType = "" OrElse _
       LCase(resolvedType.freeBasicType) = "void" OrElse _
       resolvedType.pointerCount <> 0 Then Return 0

    Dim sourceTypeText As String
    For typeIndex As Long = 0 To baseTokenCount - 1
        If typeIndex > 0 Then sourceTypeText &= " "
        sourceTypeText &= baseTokens(typeIndex)
    Next
    If RegisterSimpleBodyLocalType( _
        context, aliasName, resolvedType.freeBasicType, _
        sourceTypeText) = 0 Then Return 0
    outputText = "' C block-local scalar typedef"
    Return -1
End Function

Private Function IsSimpleCallableExpressionStatement( _
    ByRef translation As C2fbTranslationContext, _
    ByVal statementText As String _
) As Long
    Dim position As Long = 1
    SkipCSpaces(statementText, position)
    If position > Len(statementText) OrElse _
       IsIdentifierStart(Asc(statementText, position)) = 0 Then Return 0

    Dim statementName As String
    While position <= Len(statementText) AndAlso _
          IsIdentifierPart(Asc(statementText, position)) <> 0
        statementName &= Mid(statementText, position, 1)
        position += 1
    Wend
    SkipCSpaces(statementText, position)
    If position > Len(statementText) OrElse _
       Asc(statementText, position) <> Asc("(") Then Return 0
    Return CInt(IsTypeOrQualifierTokenInContext(translation, statementName) = 0)
End Function

Private Function SimpleGnuIgnoredResultCallStatement( _
    ByVal statementText As String, ByRef callStatement As String _
) As Long
    callStatement = ""
    statementText = Trim(statementText)

    Dim unwrappedText As String
    Do
        unwrappedText = StripSimpleOuterParentheses(statementText)
        If unwrappedText = statementText Then Exit Do
        statementText = unwrappedText
    Loop

    Dim blockContents As String
    Dim statementEnd As Long
    If ReadSimpleGnuStatementExpressionBlock( _
        statementText, 1, blockContents, statementEnd) = 0 OrElse _
       Trim(Mid(statementText, statementEnd)) <> "" Then Return 0

    Dim declarationEnd As Long = InStr(blockContents, ";")
    If declarationEnd <= 1 Then Return 0
    Dim declaration As String = Trim(Left(blockContents, declarationEnd - 1))
    Dim finalStatement As String = Trim(Mid(blockContents, declarationEnd + 1))
    If Right(finalStatement, 1) <> ";" Then Return 0
    finalStatement = Trim(Left(finalStatement, Len(finalStatement) - 1))
    If finalStatement = "" OrElse InStr(finalStatement, ";") <> 0 Then Return 0

    Dim typeOperator As String
    If Left(declaration, Len("__typeof__")) = "__typeof__" Then
        typeOperator = "__typeof__"
    ElseIf Left(declaration, Len("typeof")) = "typeof" Then
        typeOperator = "typeof"
    Else
        Return 0
    End If
    Dim position As Long = Len(typeOperator) + 1
    If position <= Len(declaration) AndAlso _
       IsIdentifierPart(Asc(declaration, position)) <> 0 Then Return 0
    SkipCSpaces(declaration, position)
    If position > Len(declaration) OrElse _
       Asc(declaration, position) <> Asc("(") Then Return 0
    Dim typeEnd As Long = position
    If ScanSimpleExpressionGroup( _
        declaration, typeEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim typeExpression As String = Trim(Mid( _
        declaration, position + 1, typeEnd - position - 2))
    position = typeEnd
    SkipCSpaces(declaration, position)

    If position > Len(declaration) OrElse _
       IsIdentifierStart(Asc(declaration, position)) = 0 Then Return 0
    Dim aliasStart As Long = position
    position += 1
    While position <= Len(declaration) AndAlso _
          IsIdentifierPart(Asc(declaration, position)) <> 0
        position += 1
    Wend
    Dim aliasName As String = Mid( _
        declaration, aliasStart, position - aliasStart)
    SkipCSpaces(declaration, position)
    If position > Len(declaration) OrElse _
       Asc(declaration, position) <> Asc("=") OrElse _
       (position < Len(declaration) AndAlso _
        Asc(declaration, position + 1) = Asc("=")) Then Return 0
    Dim initializer As String = Trim(Mid(declaration, position + 1))
    If initializer = "" OrElse _
       StripSimpleOuterParentheses(initializer) <> typeExpression Then Return 0

    position = 1
    SkipCSpaces(finalStatement, position)
    If position > Len(finalStatement) OrElse _
       Asc(finalStatement, position) <> Asc("(") Then Return 0
    Dim castEnd As Long = position
    If ScanSimpleExpressionGroup( _
        finalStatement, castEnd, Asc("("), Asc(")")) = 0 OrElse _
       Trim(Mid(finalStatement, position + 1, castEnd - position - 2)) <> "void" Then _
        Return 0
    position = castEnd
    SkipCSpaces(finalStatement, position)
    If Mid(finalStatement, position, Len(aliasName)) <> aliasName Then Return 0
    position += Len(aliasName)
    If position <= Len(finalStatement) AndAlso _
       IsIdentifierPart(Asc(finalStatement, position)) <> 0 Then Return 0
    SkipCSpaces(finalStatement, position)
    If position <= Len(finalStatement) Then Return 0

    ' ignore_value's local captures a function result once, then discards it.
    ' Require the identical direct call in both typeof and initializer forms.
    initializer = StripSimpleOuterParentheses(initializer)
    position = 1
    SkipCSpaces(initializer, position)
    If position > Len(initializer) OrElse _
       IsIdentifierStart(Asc(initializer, position)) = 0 Then Return 0
    position += 1
    While position <= Len(initializer) AndAlso _
          IsIdentifierPart(Asc(initializer, position)) <> 0
        position += 1
    Wend
    SkipCSpaces(initializer, position)
    If position > Len(initializer) OrElse _
       Asc(initializer, position) <> Asc("(") Then Return 0
    Dim callEnd As Long = position
    If ScanSimpleExpressionGroup( _
        initializer, callEnd, Asc("("), Asc(")")) = 0 OrElse _
       Trim(Mid(initializer, callEnd)) <> "" Then Return 0

    callStatement = initializer
    Return -1
End Function

Private Function SimpleCStatementAlwaysTerminates( _
    ByRef translation As C2fbTranslationContext, _
    ByVal statementText As String, _
    parameterNames() As String, parameterAliases() As String, _
    ByVal parameterCount As Long _
) As Long
    statementText = Trim(statementText)
    If Right(statementText, 1) = ";" Then _
        statementText = RTrim(Left(statementText, Len(statementText) - 1))
    statementText = StripSimpleOuterParentheses(statementText)
    Dim nameEnd As Long = 1
    While nameEnd <= Len(statementText) AndAlso _
          IsIdentifierPart(Asc(statementText, nameEnd)) <> 0
        nameEnd += 1
    Wend
    If nameEnd <= 1 Then Return 0
    Dim procedureName As String = Left(statementText, nameEnd - 1)
    If ParameterAlias( _
        parameterNames(), parameterAliases(), parameterCount, _
        procedureName) <> "" OrElse _
       CBodyExternalObjectIndex(translation, procedureName) >= 0 Then Return 0
    Dim position As Long = nameEnd
    SkipCSpaces(statementText, position)
    If position > Len(statementText) OrElse _
       Asc(statementText, position) <> Asc("(") Then Return 0

    Dim procedureIndex As Long = CBodyProcedureIndex( _
        translation, procedureName)
    If procedureIndex >= 0 AndAlso _
       translation.symbolTable.symbols(procedureIndex).body.isNoReturn <> 0 Then _
        Return -1

    Select Case procedureName
    Case "abort", "exit", "_Exit", "_exit", "quick_exit", _
         "__builtin_trap", "__builtin_unreachable"
        Return -1
    Case "error", "error_at_line"
        Dim callEnd As Long = position
        If ScanSimpleExpressionGroup( _
            statementText, callEnd, Asc("("), Asc(")")) = 0 OrElse _
           Trim(Mid(statementText, callEnd)) <> "" Then Return 0
        Dim argumentsText As String = Trim(Mid( _
            statementText, position + 1, callEnd - position - 2))
        Dim arguments() As String
        Dim argumentCount As Long
        If SplitSimpleCList(argumentsText, arguments(), argumentCount) = 0 OrElse _
           argumentCount = 0 Then Return 0
        Dim statusText As String = Trim(arguments(0))
        If Left(statusText, 1) = "-" Then statusText = Trim(Mid(statusText, 2))
        Dim statusValue As Long
        If EvaluateSimpleArrayBound( _
            statusText, statusValue, MAX_GENERIC_ARRAY_COUNT, -1) = 0 AndAlso _
           EvaluateGenericBodyArrayBound( _
               translation, statusText, statusValue, _
               MAX_GENERIC_ARRAY_COUNT) = 0 Then Return 0
        ' GNU error() and error_at_line() exit when STATUS is nonzero.
        Return CInt(statusValue <> 0)
    End Select
    Return 0
End Function

Private Function ParseSimpleCStatement( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef sourceText As String, _
    ByRef position As Long, _
    ByRef outputText As String, _
    ByVal indentText As String, _
    ByVal returnType As String, _
    ByRef context As SimpleBodyContext, _
    callableNames() As String, _
    ByVal callableCount As Long, _
    parameterNames() As String, _
    parameterAliases() As String, _
    parameterTypes() As String, _
    ByRef symbolCount As Long, _
    locals() As SimpleLocalVariable, _
    ByRef localCount As Long, _
    ByRef terminatesPaths As Long, _
    ByVal allowBodyReplacements As Long = -1 _
) As Long
    outputText = ""
    terminatesPaths = 0
    context.branchJump = 0
    ResetSimpleBodyFailure(context)
    SkipCSpaces(sourceText, position)
    If position > Len(sourceText) Then Return 0

    Dim wordPosition As Long = position
    Dim wordText As String
    While wordPosition <= Len(sourceText) AndAlso IsIdentifierPart(Asc(sourceText, wordPosition)) <> 0
        wordText &= Mid(sourceText, wordPosition, 1)
        wordPosition += 1
    Wend
    Dim following As Long = wordPosition
    SkipCSpaces(sourceText, following)
    If wordText <> "" AndAlso Mid(sourceText, following, 1) = ":" Then
        Dim labelName As String = SimpleSourceLabel(context, wordText, -1)
        If labelName = "" Then Return 0
        outputText = indentText & labelName & ":"
        position = following + 1
        Return -1
    End If

    If wordText = "_Static_assert" OrElse wordText = "static_assert" Then
        Dim assertionText As String
        If ReadSimpleCStatement(sourceText, position, assertionText) = 0 Then Return 0
        outputText = indentText & "' C compile-time assertion checked by the C compiler"
        Return -1
    End If

    If translation.target.profile <> C2FB_TARGET_SQLITE AndAlso allowBodyReplacements <> 0 AndAlso _
       position <= Len(sourceText) AndAlso Asc(sourceText, position) <> Asc("{") Then
        Select Case wordText
        Case "if", "else", "for", "while", "do", "switch", "case", "default", _
             "break", "continue", "goto"
            ' The expression matcher does not replace control-flow constructs.
        Case Else
            Dim statementEnd As Long = position
            Dim cStatement As String
            If ReadSimpleCStatement(sourceText, statementEnd, cStatement) <> 0 Then
                Dim replacementText As String
                Dim toFreeBasic As Long
                If C2fbReplacementRuleMatch( _
                    translation.genericC.policy, Trim(cStatement) & ";", _
                    replacementText, toFreeBasic) <> 0 Then
                    If toFreeBasic <> 0 Then
                        Dim sourceIsReturn As Long = CInt(wordText = "return")
                        If sourceIsReturn = 0 AndAlso _
                           IsTypeOrQualifierTokenInContext(translation, wordText) <> 0 Then Return 0
                        Dim isMultiLineReplacement As Long = _
                            C2fbReplacementRuleHasMultipleLines( _
                                translation.genericC.policy, Trim(cStatement) & ";")
                        Dim replacementReturnExpression As String
                        Dim replacementEndsInReturn As Long = 0
                        If isMultiLineReplacement <> 0 Then
                            replacementEndsInReturn = ReadGenericFreeBasicBlockReturn( _
                                replacementText, replacementReturnExpression)
                        End If
                        If (sourceIsReturn <> 0 AndAlso isMultiLineReplacement <> 0 AndAlso _
                            replacementEndsInReturn = 0) OrElse _
                           (isMultiLineReplacement = 0 AndAlso _
                            IsSimpleFreeBasicBodyReplacement( _
                                replacementText, sourceIsReturn) = 0) Then
                            RecordSimpleBodyFailure( _
                                context, "statement-replacement", _
                                "invalid FreeBASIC statement replacement: " & _
                                Left(cStatement, 160))
                            Return 0
                        End If
                        If sourceIsReturn <> 0 AndAlso isMultiLineReplacement = 0 Then
                            Dim sourceReturnExpression As String = _
                                Trim(Mid(cStatement, Len("return") + 1))
                            replacementReturnExpression = _
                                Trim(Mid(LTrim(replacementText), Len("return") + 1))
                            If (sourceReturnExpression = "") <> _
                               (replacementReturnExpression = "") Then Return 0
                        End If
                        If replacementEndsInReturn <> 0 OrElse sourceIsReturn <> 0 Then
                            If returnType = "void" AndAlso _
                               replacementReturnExpression <> "" Then Return 0
                            If returnType <> "void" AndAlso _
                               replacementReturnExpression = "" Then Return 0
                        End If
                        Dim rewrittenReplacement As String = RewriteGenericBodyLocalNames( _
                            replacementText, parameterNames(), parameterAliases(), symbolCount)
                        If isMultiLineReplacement <> 0 Then
                            outputText = IndentC2fbReplacement( _
                                rewrittenReplacement, indentText)
                        Else
                            outputText = indentText & rewrittenReplacement
                        End If
                        position = statementEnd
                        If sourceIsReturn <> 0 OrElse replacementEndsInReturn <> 0 Then _
                            terminatesPaths = -1
                        Return -1
                    End If

                    If Right(Trim(replacementText), 1) <> ";" Then _
                        replacementText = Trim(replacementText) & ";"
                    sourceText = Left(sourceText, position - 1) & _
                                 replacementText & Mid(sourceText, statementEnd)
                    Return ParseSimpleCStatement(translation, catalog,  _
                        sourceText, position, outputText, indentText, returnType, _
                        context, callableNames(), callableCount, parameterNames(), _
                        parameterAliases(), parameterTypes(), symbolCount, locals(), _
                        localCount, terminatesPaths, 0)
                End If
            End If
        End Select
    End If

    If wordText = "break" OrElse wordText = "continue" OrElse wordText = "goto" Then
        Dim jumpText As String
        If ReadSimpleCStatement(sourceText, position, jumpText) = 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-jump-statement", _
                "unsupported jump statement: " & Left(Mid(sourceText, position), 200))
            Return 0
        End If
        Dim target As String
        If wordText = "break" AndAlso jumpText = "break" Then
            target = SimpleBreakTarget(context)
        ElseIf wordText = "continue" AndAlso jumpText = "continue" Then
            target = SimpleContinueTarget(context)
        ElseIf wordText = "goto" Then
            Dim sourceLabel As String = Trim(Mid(jumpText, 5))
            If IsIdentifierToken(sourceLabel) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-goto-label", _
                    "unsupported goto label: " & Left(jumpText, 200))
                Return 0
            End If
            target = SimpleSourceLabel(context, sourceLabel, 0)
        Else
            Return 0
        End If
        If target = "" Then
            RecordSimpleBodyFailure( _
                context, "jump-target-not-created", _
                "could not create jump target: " & Left(jumpText, 200))
            Return 0
        End If
        outputText = indentText & "Goto " & target
        context.branchJump = -1
        Return -1
    End If
    If ParseSimpleFallthroughAnnotation(sourceText, position, outputText, indentText) <> 0 Then Return -1
    If Asc(sourceText, position) = Asc("{") Then
        Return ParseSimpleCBlock(translation, catalog, sourceText, position, outputText, indentText, returnType, context, _
                                 callableNames(), callableCount, parameterNames(), _
                                 parameterAliases(), parameterTypes(), symbolCount, locals(), localCount, _
                                 terminatesPaths)
    End If

    Dim switchPosition As Long = position
    If ParseSimpleSwitchStatement(translation, catalog, sourceText, switchPosition, outputText, indentText, _
                                  returnType, context, callableNames(), callableCount, _
                                  parameterNames(), parameterAliases(), parameterTypes(), symbolCount, _
                                  locals(), localCount, terminatesPaths) <> 0 Then
        position = switchPosition
        Return -1
    End If

    Dim conditionText As String = ""
    Dim conditionPosition As Long = position
    If ReadSimpleIfCondition(sourceText, conditionPosition, conditionText) <> 0 Then
        Dim translatedCondition As String
        Dim conditionPrelude As String
        If TranslateSequencedExpression(translation, catalog, _
                                        conditionText, translatedCondition, conditionPrelude, context, _
                                        callableNames(), callableCount, parameterNames(), _
                                        parameterAliases(), parameterTypes(), symbolCount) = 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-if-condition", _
                "unsupported if condition: " & Left(conditionText, 240))
            Return 0
        End If
        position = conditionPosition
        Dim trueBody As String
        Dim trueTerminates As Long = 0
        If ParseSimpleCStatement(translation, catalog, sourceText, position, trueBody, indentText & "    ", _
                                 returnType, context, callableNames(), callableCount, parameterNames(), _
                                 parameterAliases(), parameterTypes(), symbolCount, locals(), localCount, _
                                 trueTerminates) = 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-if-body", _
                "unsupported if body: " & Left(Mid(sourceText, position), 240))
            Return 0
        End If
        Dim trueJump As Long = context.branchJump
        Dim constantConditionValue As Long
        Dim conditionIsConstant As Long = SimpleCConditionConstantValue( _
            translation, conditionText, parameterNames(), parameterAliases(), _
            symbolCount, constantConditionValue)

        SkipCSpaces(sourceText, position)
        Dim hasElse As Long = 0
        If Mid(sourceText, position, 4) = "else" AndAlso _
           (position + 4 > Len(sourceText) OrElse _
            IsIdentifierPart(Asc(sourceText, position + 4)) = 0) Then
            position += 4
            hasElse = -1
        End If
        outputText = ""
        If conditionPrelude <> "" Then outputText = IndentSimpleBodyText(RTrim(conditionPrelude, Any Chr(10)), indentText) & Chr(10)
        outputText &= indentText & "If " & translatedCondition & " Then" & Chr(10) & trueBody
        context.branchJump = 0
        If hasElse <> 0 Then
            Dim falseBody As String
            Dim falseTerminates As Long = 0
            If ParseSimpleCStatement(translation, catalog, sourceText, position, falseBody, indentText & "    ", _
                                     returnType, context, callableNames(), callableCount, parameterNames(), _
                                     parameterAliases(), parameterTypes(), symbolCount, locals(), localCount, _
                                     falseTerminates) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-else-body", _
                    "unsupported else body: " & Left(Mid(sourceText, position), 240))
                Return 0
            End If
            outputText &= Chr(10) & indentText & "Else" & Chr(10) & falseBody
            Dim falseJump As Long = context.branchJump
            If conditionIsConstant <> 0 Then
                If constantConditionValue <> 0 Then
                    terminatesPaths = trueTerminates
                    context.branchJump = trueJump
                Else
                    terminatesPaths = falseTerminates
                    context.branchJump = falseJump
                End If
            Else
                terminatesPaths = CInt( _
                    trueTerminates <> 0 AndAlso falseTerminates <> 0)
                context.branchJump = CInt( _
                    trueJump <> 0 AndAlso falseJump <> 0)
            End If
        Else
            If conditionIsConstant <> 0 AndAlso _
               constantConditionValue <> 0 Then
                terminatesPaths = trueTerminates
                context.branchJump = trueJump
            Else
                context.branchJump = 0
            End If
        End If
        outputText &= Chr(10) & indentText & "End If"
        Return -1
    End If

    Dim doPosition As Long = position
    If Mid(sourceText, doPosition, 2) = "do" AndAlso _
       (doPosition + 2 > Len(sourceText) OrElse _
        IsIdentifierPart(Asc(sourceText, doPosition + 2)) = 0) Then
        doPosition += 2
        SkipCSpaces(sourceText, doPosition)
        Dim breakLabel As String = NewSimpleFlowLabel(context)
        Dim continueLabel As String = NewSimpleFlowLabel(context)
        If PushSimpleControlFrame(context, breakLabel, continueLabel) = 0 Then Return 0
        Dim loopBody As String
        Dim loopTerminates As Long = 0
        If ParseSimpleCStatement(translation, catalog, sourceText, doPosition, loopBody, _
                                  indentText & "    ", returnType, context, _
                                  callableNames(), callableCount, parameterNames(), _
                                  parameterAliases(), parameterTypes(), symbolCount, locals(), localCount, _
                                  loopTerminates) = 0 Then Return 0
        Dim doFrameIndex As Long = context.frameCount - 1
        Dim hasBreak As Long = CInt( _
            context.frames(doFrameIndex).hasBreak <> 0 OrElse _
            context.frames(doFrameIndex).hasGotoExit <> 0 OrElse _
            context.frames(doFrameIndex).pendingGotoLabels <> "")
        context.frameCount -= 1
        context.branchJump = 0

        SkipCSpaces(sourceText, doPosition)
        If Mid(sourceText, doPosition, 5) <> "while" OrElse _
           (doPosition + 5 <= Len(sourceText) AndAlso _
            IsIdentifierPart(Asc(sourceText, doPosition + 5)) <> 0) Then Return 0
        doPosition += 5
        SkipCSpaces(sourceText, doPosition)
        If doPosition > Len(sourceText) OrElse _
           Asc(sourceText, doPosition) <> Asc("(") Then Return 0

        Dim conditionStart As Long = doPosition + 1
        If ScanSimpleExpressionGroup(sourceText, doPosition, Asc("("), Asc(")")) = 0 Then Return 0
        conditionText = Trim(Mid(sourceText, conditionStart, _
                                  doPosition - conditionStart - 1))
        If Len(conditionText) = 0 Then Return 0
        Dim translatedCondition As String
        Dim conditionPrelude As String
        If TranslateSequencedExpression(translation, catalog, _
                                        conditionText, translatedCondition, conditionPrelude, context, _
                                        callableNames(), callableCount, parameterNames(), _
                                        parameterAliases(), parameterTypes(), symbolCount) = 0 Then Return 0
        SkipCSpaces(sourceText, doPosition)
        If doPosition > Len(sourceText) OrElse _
           Asc(sourceText, doPosition) <> Asc(";") Then Return 0
        doPosition += 1
        position = doPosition
        outputText = indentText & "Do" & Chr(10) & loopBody & Chr(10) & _
                     indentText & continueLabel & ":" & Chr(10) & _
                     IIf(conditionPrelude <> "", IndentSimpleBodyText(RTrim(conditionPrelude, Any Chr(10)), indentText & "    ") & Chr(10), "") & _
                     indentText & "Loop While " & translatedCondition & Chr(10) & _
                     indentText & breakLabel & ":"
        terminatesPaths = CInt(loopTerminates <> 0 OrElse _
            (hasBreak = 0 AndAlso conditionPrelude = "" AndAlso _
             SimpleCConditionAlwaysTrue(translation, conditionText, _
                 parameterNames(), parameterAliases(), symbolCount) <> 0))
        Return -1
    End If

    Dim forPosition As Long = position
    If Mid(sourceText, forPosition, 3) = "for" AndAlso _
       (forPosition + 3 > Len(sourceText) OrElse _
        IsIdentifierPart(Asc(sourceText, forPosition + 3)) = 0) Then
        forPosition += 3
        SkipCSpaces(sourceText, forPosition)
        If forPosition > Len(sourceText) OrElse Asc(sourceText, forPosition) <> Asc("(") Then Return 0
        Dim headerStart As Long = forPosition + 1
        If ScanSimpleExpressionGroup(sourceText, forPosition, Asc("("), Asc(")")) = 0 Then Return 0
        Dim headerText As String = Mid(sourceText, headerStart, forPosition - headerStart - 1)
        Dim firstSeparator As Long = 0
        Dim secondSeparator As Long = 0
        Dim depth As Long = 0
        Dim quoteByte As Long = 0
        For i As Long = 1 To Len(headerText)
            Dim c As Long = Asc(headerText, i)
            If quoteByte <> 0 Then
                If c = Asc("\") Then
                    i += 1
                ElseIf c = quoteByte Then
                    quoteByte = 0
                End If
                Continue For
            ElseIf c = Asc("'") OrElse c = Asc("""") Then
                quoteByte = c
                Continue For
            End If
            If Asc(headerText, i) = Asc("(") Then depth += 1
            If Asc(headerText, i) = Asc(")") Then depth -= 1
            If depth = 0 AndAlso Asc(headerText, i) = Asc(";") Then
                If firstSeparator = 0 Then
                    firstSeparator = i
                ElseIf secondSeparator = 0 Then
                    secondSeparator = i
                Else
                    Return 0
                End If
            End If
        Next
        If firstSeparator = 0 OrElse secondSeparator = 0 Then Return 0

        Dim initializationText As String = Trim(Left(headerText, firstSeparator - 1))
        Dim conditionPrelude As String
        Dim loopCondition As String = Trim(Mid(headerText, firstSeparator + 1, _
                                             secondSeparator - firstSeparator - 1))
        Dim incrementText As String = Trim(Mid(headerText, secondSeparator + 1))
        Dim translatedInitialization As String = ""
        Dim translatedIncrement As String = ""
        Dim statementAccepted As Long
        Dim initializationTerminates As Long = 0
        If PushSimpleBodyScope(context, symbolCount, localCount) = 0 Then Return 0
        If Len(initializationText) <> 0 Then
            statementAccepted = TranslateSimpleDeclarationStatement(translation, catalog,  _
                initializationText, translatedInitialization, context, locals(), localCount, _
                callableNames(), callableCount, parameterNames(), parameterAliases(), parameterTypes(), symbolCount)
            If statementAccepted = 0 Then
                statementAccepted = TranslateSimpleAssignmentStatement(translation, catalog,  _
                    initializationText, translatedInitialization, context, callableNames(), callableCount, _
                    parameterNames(), parameterAliases(), parameterTypes(), symbolCount, _
                    initializationTerminates)
            End If
            If statementAccepted = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-for-initializer", _
                    "unsupported for initializer: " & Left(initializationText, 200))
                Return 0
            End If
        End If
        If Len(loopCondition) = 0 Then
            loopCondition = "True"
        Else
            Dim translatedCondition As String
            If TranslateSequencedExpression(translation, catalog, _
                                            loopCondition, translatedCondition, conditionPrelude, context, _
                                            callableNames(), callableCount, parameterNames(), _
                                            parameterAliases(), parameterTypes(), symbolCount) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-for-condition", _
                    "unsupported for condition: " & Left(loopCondition, 200))
                Return 0
            End If
            loopCondition = translatedCondition
        End If
        If Len(incrementText) <> 0 Then
            Dim incrementTerminates As Long = 0
            If TranslateSimpleAssignmentStatement(translation, catalog, incrementText, translatedIncrement, context, _
                                                  callableNames(), callableCount, _
                                                  parameterNames(), parameterAliases(), parameterTypes(), _
                                                  symbolCount, incrementTerminates) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-for-increment", _
                    "unsupported for increment: " & Left(incrementText, 200))
                Return 0
            End If
        End If

        position = forPosition
        Dim breakLabel As String = NewSimpleFlowLabel(context)
        Dim continueLabel As String = NewSimpleFlowLabel(context)
        If PushSimpleControlFrame(context, breakLabel, continueLabel) = 0 Then Return 0
        Dim loopBody As String
        Dim loopTerminates As Long = 0
        If ParseSimpleCStatement(translation, catalog, sourceText, position, loopBody, indentText & "    ", _
                                 returnType, context, callableNames(), callableCount, parameterNames(), _
                                 parameterAliases(), parameterTypes(), symbolCount, locals(), localCount, _
                                 loopTerminates) = 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-for-body", _
                "unsupported for body: " & Left(Mid(sourceText, position), 240))
            Return 0
        End If
        Dim forFrameIndex As Long = context.frameCount - 1
        Dim hasBreak As Long = CInt( _
            context.frames(forFrameIndex).hasBreak <> 0 OrElse _
            context.frames(forFrameIndex).hasGotoExit <> 0 OrElse _
            context.frames(forFrameIndex).pendingGotoLabels <> "")
        context.frameCount -= 1
        PopSimpleBodyScope(context, symbolCount, localCount)
        context.branchJump = 0
        outputText = ""
        If Len(translatedInitialization) <> 0 Then
            outputText = IndentSimpleBodyText(translatedInitialization, indentText) & Chr(10)
        End If
        If conditionPrelude <> "" Then
            outputText &= indentText & "Do" & Chr(10) & _
                          IndentSimpleBodyText(conditionPrelude & "If (" & loopCondition & " = 0) Then Goto " & breakLabel, indentText & "    ") & Chr(10) & loopBody
        Else
            outputText &= indentText & "While " & loopCondition & Chr(10) & loopBody
        End If
        outputText &= Chr(10) & indentText & continueLabel & ":"
        If Len(translatedIncrement) <> 0 Then
            outputText &= Chr(10) & IndentSimpleBodyText(translatedIncrement, indentText & "    ")
        End If
        outputText &= Chr(10) & indentText & IIf(conditionPrelude <> "", "Loop", "Wend") & Chr(10) & indentText & breakLabel & ":"
        If hasBreak = 0 AndAlso loopCondition = "True" Then terminatesPaths = -1
        Return -1
    End If

    Dim whilePosition As Long = position
    If Mid(sourceText, whilePosition, 5) = "while" AndAlso _
       (whilePosition + 5 > Len(sourceText) OrElse _
        IsIdentifierPart(Asc(sourceText, whilePosition + 5)) = 0) Then
        whilePosition += 5
        SkipCSpaces(sourceText, whilePosition)
        If whilePosition > Len(sourceText) OrElse Asc(sourceText, whilePosition) <> Asc("(") Then Return 0
        Dim conditionStart As Long = whilePosition + 1
        If ScanSimpleExpressionGroup(sourceText, whilePosition, Asc("("), Asc(")")) = 0 Then Return 0
        conditionText = Trim(Mid(sourceText, conditionStart, whilePosition - conditionStart - 1))
        Dim translatedCondition As String
        Dim conditionPrelude As String
        If TranslateSequencedExpression(translation, catalog, _
                                        conditionText, translatedCondition, conditionPrelude, context, _
                                        callableNames(), callableCount, parameterNames(), _
                                        parameterAliases(), parameterTypes(), symbolCount) = 0 Then Return 0
        position = whilePosition
        Dim breakLabel As String = NewSimpleFlowLabel(context)
        Dim continueLabel As String = NewSimpleFlowLabel(context)
        If PushSimpleControlFrame(context, breakLabel, continueLabel) = 0 Then Return 0
        Dim loopBody As String
        Dim loopTerminates As Long = 0
        If ParseSimpleCStatement(translation, catalog, sourceText, position, loopBody, indentText & "    ", _
                                 returnType, context, callableNames(), callableCount, parameterNames(), _
                                 parameterAliases(), parameterTypes(), symbolCount, locals(), localCount, _
                                 loopTerminates) = 0 Then Return 0
        Dim whileFrameIndex As Long = context.frameCount - 1
        Dim hasBreak As Long = CInt( _
            context.frames(whileFrameIndex).hasBreak <> 0 OrElse _
            context.frames(whileFrameIndex).hasGotoExit <> 0 OrElse _
            context.frames(whileFrameIndex).pendingGotoLabels <> "")
        context.frameCount -= 1
        context.branchJump = 0
        If conditionPrelude <> "" Then
            outputText = indentText & "Do" & Chr(10) & _
                         IndentSimpleBodyText(conditionPrelude & "If (" & translatedCondition & " = 0) Then Goto " & breakLabel, indentText & "    ") & Chr(10) & loopBody
        Else
            outputText = indentText & "While " & translatedCondition & Chr(10) & loopBody
        End If
        outputText &= Chr(10) & indentText & continueLabel & ":" & _
                      Chr(10) & indentText & IIf(conditionPrelude <> "", "Loop", "Wend") & Chr(10) & indentText & breakLabel & ":"
        If hasBreak = 0 AndAlso conditionPrelude = "" AndAlso _
           SimpleCConditionAlwaysTrue(translation, conditionText, _
               parameterNames(), parameterAliases(), symbolCount) <> 0 Then _
            terminatesPaths = -1
        Return -1
    End If

    Dim returnExpression As String = ""
    Dim returnPosition As Long = position
    If ReadSimpleReturn(sourceText, returnPosition, returnExpression) <> 0 Then
        Dim translatedReturn As String = ""
        Dim returnPrelude As String
        If TranslateSimpleReturnValue(translation, catalog, returnType, returnExpression, translatedReturn, returnPrelude, context, _
                                      callableNames(), callableCount, parameterNames(), _
                                      parameterAliases(), parameterTypes(), symbolCount) = 0 Then Return 0
        outputText = ""
        If returnPrelude <> "" Then outputText = IndentSimpleBodyText(RTrim(returnPrelude, Any Chr(10)), indentText) & Chr(10)
        outputText &= indentText & "Return"
        If Len(translatedReturn) <> 0 Then outputText &= " " & translatedReturn
        position = returnPosition
        terminatesPaths = -1
        Return -1
    End If

    Dim simpleText As String
    If ReadSimpleCStatement(sourceText, position, simpleText) = 0 Then Return 0
    simpleText = StripSimpleNonsemanticAttributes(simpleText)
    Dim ignoredResultCall As String
    If SimpleGnuIgnoredResultCallStatement( _
        simpleText, ignoredResultCall) <> 0 Then
        Dim translatedIgnoredResult As String
        Dim ignoredResultTerminates As Long = 0
        If TranslateSimpleAssignmentStatement( _
            translation, catalog, ignoredResultCall, translatedIgnoredResult, _
            context, callableNames(), callableCount, parameterNames(), _
            parameterAliases(), parameterTypes(), symbolCount, _
            ignoredResultTerminates) = 0 Then Return 0
        outputText = IndentSimpleBodyText(translatedIgnoredResult, indentText)
        terminatesPaths = ignoredResultTerminates
        Return -1
    End If
    Dim alignmentStrippedText As String
    Dim alignmentValue As Long
    If StripSimpleAlignmentSpecifiers( _
        simpleText, alignmentStrippedText, alignmentValue) <> 0 AndAlso _
       alignmentStrippedText <> simpleText Then
        Dim translatedAlignedDeclaration As String
        If TranslateSimpleDeclarationStatement( _
            translation, catalog, simpleText, translatedAlignedDeclaration, _
            context, locals(), localCount, callableNames(), callableCount, _
            parameterNames(), parameterAliases(), parameterTypes(), _
            symbolCount) = 0 Then Return 0
        outputText = IndentSimpleBodyText( _
            translatedAlignedDeclaration, indentText)
        Return -1
    End If
    If IsSimpleCallableExpressionStatement(translation, simpleText) <> 0 Then
        Dim translatedCall As String
        Dim translatedCallTerminates As Long = 0
        If TranslateSimpleAssignmentStatement( _
            translation, catalog, simpleText, translatedCall, context, _
            callableNames(), callableCount, parameterNames(), _
            parameterAliases(), parameterTypes(), symbolCount, _
            translatedCallTerminates) = 0 Then Return 0
        outputText = IndentSimpleBodyText(translatedCall, indentText)
        terminatesPaths = CInt( _
            translatedCallTerminates <> 0 OrElse _
            SimpleCStatementAlwaysTerminates( _
                translation, simpleText, parameterNames(), parameterAliases(), _
                symbolCount) <> 0)
        Return -1
    End If
    If IsUnusedLocalRecordDefinition( _
        simpleText, Mid(sourceText, position)) <> 0 Then
        outputText = indentText & "' unused local record definition"
        Return -1
    End If
    Dim localRecordOutput As String
    Dim localRecordTag As String
    Dim localRecordDeclaration As String
    If TranslateSimpleLocalRecordTypeDefinition( _
        translation, catalog, simpleText, localRecordOutput, context, _
        localRecordTag, localRecordDeclaration) <> 0 Then
        outputText = indentText & localRecordOutput
        If localRecordDeclaration <> "" Then
            Dim declarationText As String = _
                "struct " & localRecordTag & " " & localRecordDeclaration
            Dim declarationOutput As String
            If TranslateSimpleDeclarationStatement( _
                translation, catalog, declarationText, declarationOutput, _
                context, locals(), localCount, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                symbolCount) = 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-local-record-declarator", _
                    "could not translate declarators following a block-local record definition")
                Return 0
            End If
            If declarationOutput <> "" Then _
                outputText &= Chr(10) & _
                    IndentSimpleBodyText(declarationOutput, indentText)
        End If
        Return -1
    End If
    If TranslateSimpleLocalTypeTypedef( _
        translation, catalog, simpleText, localRecordOutput, context) <> 0 Then
        outputText = indentText & localRecordOutput
        Return -1
    End If
    Dim localEnumOutput As String
    If TranslateSimpleLocalEnumDefinition( _
        translation, catalog, simpleText, localEnumOutput, context, locals(), _
        localCount, parameterNames(), parameterAliases(), parameterTypes(), _
        symbolCount) <> 0 Then
        outputText = indentText & localEnumOutput
        Return -1
    End If
    If IsSimpleUnusedParameterStatement(simpleText) <> 0 OrElse IsSimpleVoidZeroStatement(simpleText) <> 0 Then
        outputText = indentText & "' C unused-parameter annotation"
        Return -1
    End If
    Dim memoryBarrierOutput As String
    If TranslateSimpleGnuMemoryClobberStatement( _
        simpleText, memoryBarrierOutput) <> 0 Then
        outputText = IndentSimpleBodyText(memoryBarrierOutput, indentText)
        Return -1
    End If
    Dim translatedStatement As String
    Dim translatedStatementTerminates As Long = 0
    If TranslateSimpleDeclarationStatement(translation, catalog, simpleText, translatedStatement, context, locals(), localCount, _
                                           callableNames(), callableCount, parameterNames(), _
                                           parameterAliases(), parameterTypes(), symbolCount) <> 0 Then
        outputText = IndentSimpleBodyText(translatedStatement, indentText)
        Return -1
    End If
    If TranslateSimpleAssignmentStatement(translation, catalog, simpleText, translatedStatement, context, callableNames(), _
                                          callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
                                          symbolCount, translatedStatementTerminates) = 0 Then Return 0
    outputText = IndentSimpleBodyText(translatedStatement, indentText)
    terminatesPaths = CInt( _
        translatedStatementTerminates <> 0 OrElse _
        SimpleCStatementAlwaysTerminates( _
            translation, simpleText, parameterNames(), parameterAliases(), _
            symbolCount) <> 0)
    Return -1
End Function

/' end of c2fb_body_statements.bi '/
