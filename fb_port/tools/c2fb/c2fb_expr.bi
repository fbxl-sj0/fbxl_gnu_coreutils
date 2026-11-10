/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_expr.bi

    Purpose:

        Parse the supported C expression subset before emitting FreeBASIC.

    Responsibilities:

        - Preserve C precedence, associativity, and short-circuit evaluation.
        - Keep C boolean values and known arithmetic types explicit.
        - Read bounded numeric, character, and string literals.
        - Dispatch supported array and record compound literals to shared
          lowering that retains their C object storage.
        - Translate supported scalar casts, pointer casts, and conditionals.
        - Select supported C11/C23 generic associations from expression types.
        - Lower fixed-width byte-swap builtins without host-endian assumptions.
        - Lower C23 leading/trailing zero-count builtins with explicit widths.
        - Lower C11/C23 alignment operators through translated type layouts.
        - Fold supported __builtin_constant_p queries without evaluating
          runtime arguments.
        - Lower the supported GNU obstack-finish statement expression with
          ordered field updates and recognize the source-unit type alias.
        - Lower typeof-captured GNU call results without duplicate evaluation.
        - Preserve typed calls through callback parameters and file-scope objects.
        - Continue postfix calls through callback-valued call results.
        - Delegate SQLite-owned identifier and accessor policy to the
          SQLite body policy module.
        - Retain sequenced side effects as statements attached to each value.
        - Apply exact-token body expression overrides before C parsing.
        - Resolve sizeof for fixed array members reached through pointer casts.
        - Keep sizeof operands unevaluated and adapt port array member access.
        - Reduce sizeof(array)/sizeof(array[0]) using the captured array extent.
        - Reject trailing tokens and expressions whose required types are unknown.

    This file intentionally does NOT contain:

        - SQLite-owned symbol policy, statement parsing, or C preprocessor evaluation.
        - A complete C type system or validation of unported structure layouts.
'/

' The C read type can differ from a port field's storage type. The prelude is
' emitted at the value's evaluation site, with a newline after each statement;
' branch-dependent preludes must never be moved outside their branch.

Private Function MapCRecordTypePrefix( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceType As String _
) As String
    sourceType = Trim(sourceType)
    Dim prefix As String = ""
    If Left(sourceType, 13) = "const struct " Then
        prefix = "Const "
        sourceType = Mid(sourceType, 14)
    ElseIf Left(sourceType, 12) = "const union " Then
        prefix = "Const "
        sourceType = Mid(sourceType, 13)
    ElseIf Left(sourceType, 7) = "struct " Then
        sourceType = Mid(sourceType, 8)
    ElseIf Left(sourceType, 6) = "union " Then
        sourceType = Mid(sourceType, 7)
    Else
        Return sourceType
    End If

    Dim tagEnd As Long = 1
    While tagEnd <= Len(sourceType) AndAlso _
          IsIdentifierPart(Asc(sourceType, tagEnd)) <> 0
        tagEnd += 1
    Wend
    If tagEnd = 1 Then Return ""
    Dim sourceRecord As String = Left(sourceType, tagEnd - 1)
    Dim freeBasicRecord As String = MappedFbBodyRecord( _
        translation, catalog, sourceRecord)
    If freeBasicRecord = "" Then _
        freeBasicRecord = LookupCBodyRecordBindingInContext( _
            translation, sourceRecord)
    If freeBasicRecord = "" Then Return ""
    Return prefix & freeBasicRecord & Mid(sourceType, tagEnd)
End Function


Private Function ReadSimpleCTypeCast( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal inputExpression As String, _
    ByRef position As Long, _
    ByRef freeBasicType As String, _
    ByRef isPointerCast As Long, _
    ByVal allowAggregateType As Long = 0, _
    ByVal bodyContext As SimpleBodyContext Ptr = 0 _
) As Long
    freeBasicType = ""
    isPointerCast = 0
    If position > Len(inputExpression) OrElse _
       Asc(inputExpression, position) <> Asc("(") Then Return 0

    Dim typeStart As Long = position + 1
    Dim closingPosition As Long = position
    If ScanSimpleExpressionGroup(inputExpression, closingPosition, Asc("("), Asc(")")) = 0 Then Return 0
    closingPosition -= 1

    Dim typeText As String = Trim(Mid(inputExpression, typeStart, _
                                      closingPosition - typeStart))
    If Len(typeText) = 0 Then Return 0
    Dim originalTypeText As String = typeText
    typeText = MapCRecordTypePrefix(translation, catalog, typeText)
    If typeText = "" Then Return 0

    Dim tokens() As String
    Dim tokenCount As Long = 0
    TokenizeCDeclaration(typeText, tokens(), tokenCount)
    If tokenCount = 0 Then Return 0
    If typeText <> originalTypeText AndAlso InStr(typeText, "*") <> 0 Then
        ' MapCRecordTypePrefix substitutes an emitted FreeBASIC record name
        ' into the C type text. Resolve those mapped pointer casts directly;
        ' feeding the generated c2fb_ record name back through the C typedef
        ' resolver can degrade a valid record pointer to Any Ptr.
        Dim mappedBaseType As String
        Dim mappedPointerCount As Long = 0
        Dim mappedTypeIsValid As Long = -1
        For tokenIndex As Long = 0 To tokenCount - 1
            Select Case LCase(tokens(tokenIndex))
            Case "*"
                mappedPointerCount += 1
            Case "const"
                If mappedPointerCount = 0 Then
                    If mappedBaseType <> "" Then mappedBaseType &= " "
                    mappedBaseType &= "Const"
                End If
            Case "volatile", "restrict", "__restrict", "__restrict__"
                ' Pointer qualifiers do not change the value type emitted by
                ' this expression parser.
            Case Else
                If IsIdentifierToken(tokens(tokenIndex)) = 0 Then
                    mappedTypeIsValid = 0
                    Exit For
                End If
                If mappedBaseType <> "" Then mappedBaseType &= " "
                mappedBaseType &= tokens(tokenIndex)
            End Select
        Next
        If mappedTypeIsValid <> 0 AndAlso mappedBaseType <> "" AndAlso _
           mappedPointerCount > 0 Then
            freeBasicType = mappedBaseType
            For pointerIndex As Long = 1 To mappedPointerCount
                freeBasicType &= " Ptr"
            Next
            isPointerCast = -1
            position = closingPosition + 1
            Return -1
        End If
    End If
    If bodyContext <> 0 Then
        Dim expandedTypeText As String
        For typeTokenIndex As Long = 0 To tokenCount - 1
            Dim localTypeText As String
            If typeTokenIndex = 0 OrElse _
               (tokens(typeTokenIndex - 1) <> "struct" AndAlso _
                tokens(typeTokenIndex - 1) <> "union" AndAlso _
                tokens(typeTokenIndex - 1) <> "enum") Then
                localTypeText = SimpleBodyLocalCType( _
                    bodyContext[0], tokens(typeTokenIndex))
            End If
            If expandedTypeText <> "" Then expandedTypeText &= " "
            If localTypeText <> "" Then
                expandedTypeText &= localTypeText
            Else
                expandedTypeText &= tokens(typeTokenIndex)
            End If
        Next
        If expandedTypeText <> typeText Then
            typeText = expandedTypeText
            TokenizeCDeclaration(typeText, tokens(), tokenCount)
            If tokenCount = 0 Then Return 0
        End If
    End If
    Dim callbackResult As C2fbCallbackTypeResultModel
    ResolveCBodyCallbackTypeInContext( _
        translation, catalog, tokens(), 0, tokenCount - 1, _
        callbackResult, 0, C2FB_TYPE_MAPPING_BODY)
    If callbackResult.status = C2FB_CALLBACK_TYPE_UNSUPPORTED Then Return 0
    If callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED AndAlso _
       callbackResult.callbackName = "" Then
        freeBasicType = callbackResult.freeBasicType
        isPointerCast = -1
        position = closingPosition + 1
        Return -1
    End If

    Dim hasPointer As Long = 0
    For i As Long = 0 To tokenCount - 1
        If tokens(i) = "*" Then
            hasPointer = -1
        ElseIf IsIdentifierToken(tokens(i)) = 0 Then
            Return 0
        ElseIf hasPointer <> 0 AndAlso IsQualifierToken(tokens(i)) = 0 Then
            ' A declarator can only have pointer qualifiers after its stars.
            ' Otherwise (a * b) would be mistaken for an opaque pointer cast.
            Return 0
        End If
    Next

    Dim resolvedCastType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        translation, catalog, tokens(), 0, tokenCount - 1, resolvedCastType)
    If resolvedCastType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0
    freeBasicType = resolvedCastType.freeBasicType
    Dim pointerCount As Long = resolvedCastType.pointerCount
    Dim layoutType As String = NormalizeFbBodyType(catalog, freeBasicType)
    Dim layoutPointerType As String = layoutType
    If Left(layoutPointerType, 6) = "Const " Then _
        layoutPointerType = Mid(layoutPointerType, 7)
    Dim layoutPointerCount As Long = 0
    While Right(layoutPointerType, 4) = " Ptr"
        layoutPointerType = Left(layoutPointerType, Len(layoutPointerType) - 4)
        layoutPointerCount += 1
    Wend
    If IsCBodyCallbackTypeInContext(translation, freeBasicType) <> 0 Then
        isPointerCast = -1
    ElseIf pointerCount > 0 AndAlso (hasPointer <> 0 OrElse _
       C2fbTypeRecognitionStatusInContext( _
           translation, catalog, tokens(), 0, tokenCount - 1) = _
       C2FB_TYPE_RESOLUTION_RESOLVED) AndAlso _
       InStr(freeBasicType, "Ptr") <> 0 Then
        isPointerCast = -1
    ElseIf layoutPointerCount > 0 Then
        ' An imported FreeBASIC typedef can itself be a pointer, even when the
        ' corresponding C typedef names an anonymous record and is not indexed
        ' as an ordinary body alias. Keep the public alias for emitted code,
        ' but use its resolved layout to recognize pointer operations.
        isPointerCast = -1
    ElseIf pointerCount = 0 AndAlso _
           C2fbTypeRecognitionStatusInContext( _
               translation, catalog, tokens(), 0, tokenCount - 1) = _
           C2FB_TYPE_RESOLUTION_RESOLVED Then
        isPointerCast = 0
    ElseIf allowAggregateType <> 0 AndAlso pointerCount = 0 AndAlso _
           CBodyRecordSizeIsKnown( _
               translation, catalog, _
               CBodyRecordName( _
                   translation, catalog, freeBasicType)) <> 0 Then
        isPointerCast = 0
    Else
        freeBasicType = ""
        Return 0
    End If

    position = closingPosition + 1
    Return -1
End Function

Private Function CBodyCastMemberArraySizeofExpression( _
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

    Dim innerExpression As String = Trim(Mid( _
        sourceText, groupStart + 1, groupEnd - groupStart - 2))
    Dim followingText As String = Trim(Mid(sourceText, groupEnd))
    Dim ownerExpression As String
    Dim fieldName As String
    Dim operandEnd As Long = groupEnd

    If Left(followingText, 2) = "->" OrElse _
       Left(followingText, 1) = "." Then
        ownerExpression = Trim(Mid( _
            sourceText, groupStart, groupEnd - groupStart))
        Dim operatorLength As Long = IIf(Left(followingText, 2) = "->", 2, 1)
        Dim fieldPosition As Long = groupEnd + operatorLength
        While fieldPosition <= Len(sourceText) AndAlso _
              IsSpaceByte(Asc(sourceText, fieldPosition)) <> 0
            fieldPosition += 1
        Wend
        If fieldPosition > Len(sourceText) OrElse _
           IsIdentifierStart(Asc(sourceText, fieldPosition)) = 0 Then Return 0
        Dim fieldStart As Long = fieldPosition
        fieldPosition += 1
        While fieldPosition <= Len(sourceText) AndAlso _
              IsIdentifierPart(Asc(sourceText, fieldPosition)) <> 0
            fieldPosition += 1
        Wend
        fieldName = Mid(sourceText, fieldStart, fieldPosition - fieldStart)
        SkipCSpaces(sourceText, fieldPosition)
        If Mid(sourceText, fieldPosition, 1) = "." OrElse _
           Mid(sourceText, fieldPosition, 2) = "->" OrElse _
           Mid(sourceText, fieldPosition, 1) = "[" OrElse _
           Mid(sourceText, fieldPosition, 1) = "(" Then Return 0
        operandEnd = fieldPosition
    Else
        Dim operatorPosition As Long = 0
        Dim operatorLength As Long = 0
        Dim parenthesisDepth As Long = 0
        Dim bracketDepth As Long = 0
        Dim braceDepth As Long = 0
        Dim quoteByte As Long = 0
        Dim escaped As Long = 0
        For scanPosition As Long = 1 To Len(innerExpression)
            Dim currentByte As Long = Asc(innerExpression, scanPosition)
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
            If currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
                quoteByte = currentByte
            ElseIf currentByte = Asc("(") Then
                parenthesisDepth += 1
            ElseIf currentByte = Asc(")") Then
                If parenthesisDepth = 0 Then Return 0
                parenthesisDepth -= 1
            ElseIf currentByte = Asc("[") Then
                bracketDepth += 1
            ElseIf currentByte = Asc("]") Then
                If bracketDepth = 0 Then Return 0
                bracketDepth -= 1
            ElseIf currentByte = Asc("{") Then
                braceDepth += 1
            ElseIf currentByte = Asc("}") Then
                If braceDepth = 0 Then Return 0
                braceDepth -= 1
            ElseIf parenthesisDepth = 0 AndAlso _
                   bracketDepth = 0 AndAlso braceDepth = 0 Then
                If currentByte = Asc("-") AndAlso _
                   Mid(innerExpression, scanPosition + 1, 1) = ">" Then
                    If operatorPosition <> 0 Then Return 0
                    operatorPosition = scanPosition
                    operatorLength = 2
                ElseIf currentByte = Asc(".") Then
                    If operatorPosition <> 0 Then Return 0
                    operatorPosition = scanPosition
                    operatorLength = 1
                End If
            End If
        Next
        If operatorPosition = 0 OrElse parenthesisDepth <> 0 OrElse _
           bracketDepth <> 0 OrElse braceDepth <> 0 OrElse quoteByte <> 0 Then _
            Return 0
        ownerExpression = Trim(Left(innerExpression, operatorPosition - 1))
        fieldName = Trim(Mid( _
            innerExpression, operatorPosition + operatorLength))
        If IsIdentifierToken(fieldName) = 0 Then Return 0
    End If

    ' Strip grouping parentheses around the pointer cast, leaving the cast
    ' itself for the shared C type resolver.
    While Len(ownerExpression) >= 2 AndAlso _
          Left(ownerExpression, 1) = "(" AndAlso _
          Right(ownerExpression, 1) = ")"
        Dim ownerGroupEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            ownerExpression, ownerGroupEnd, Asc("("), Asc(")")) = 0 OrElse _
           ownerGroupEnd <> Len(ownerExpression) + 1 Then Exit While
        ownerExpression = Trim(Mid( _
            ownerExpression, 2, Len(ownerExpression) - 2))
    Wend

    Dim castPosition As Long = 1
    Dim castType As String
    Dim isPointerCast As Long
    If ReadSimpleCTypeCast( _
        translation, catalog, ownerExpression, castPosition, _
        castType, isPointerCast) = 0 OrElse isPointerCast = 0 OrElse _
       Right(castType, 4) <> " Ptr" Then Return 0
    Dim recordType As String = Left(castType, Len(castType) - 4)
    Dim mappedRecord As String = CBodyRecordName( _
        translation, catalog, recordType)
    Dim cField As Long = CBodyRecordFieldIndex( _
        translation, catalog, mappedRecord, fieldName)
    If cField < 0 Then _
        cField = CBodyRecordFieldIndex( _
            translation, catalog, recordType, fieldName)
    Dim fbRecord As String = MappedFbBodyRecord( _
        translation, catalog, mappedRecord)
    If fbRecord = "" Then fbRecord = recordType
    Dim fbField As Long = LookupFbBodyField( _
        translation, catalog, fbRecord, fieldName, cField)

    Dim fieldSize As Long = 0
    If fbField >= 0 Then
        With catalog.bodyFields(fbField)
            If .isArray <> 0 AndAlso .arrayCount > 0 Then
                Dim fieldType As String = .typeName
                Dim fieldPointerDepth As Long = 0
                While Right(LCase(fieldType), 4) = " ptr"
                    fieldType = Trim(Left(fieldType, Len(fieldType) - 4))
                    fieldPointerDepth += 1
                Wend
                Dim elementSize As Long
                If fieldPointerDepth > 0 Then
                    elementSize = GenericHeaderPreprocessorSizeValue( _
                        translation, "__SIZEOF_POINTER__")
                Else
                    elementSize = GenericHeaderFreeBasicScalarSize( _
                        translation, fieldType)
                    If elementSize <= 0 Then _
                        elementSize = GenericHeaderSimpleRecordSizeInBytes( _
                            translation, fieldType)
                End If
                If elementSize > 0 AndAlso _
                   .arrayCount <= MAX_GENERIC_ARRAY_BOUND_VALUE \ elementSize Then _
                    fieldSize = elementSize * .arrayCount
            End If
        End With
    End If
    If fieldSize <= 0 Then _
        fieldSize = GenericHeaderRecordArrayMemberSizeInBytes( _
            translation, recordType, fieldName)
    If fieldSize <= 0 Then Return 0

    sizeExpression = "Cast(c2fb_size_t, " & Trim(Str(fieldSize)) & "ULL)"
    position = operandEnd
    Return -1
End Function

Private Type SimpleExpressionValue
    text As String
    typeName As String
    pointerCount As Long
    volatileMask As Long
    volatileReadLowered As Long
    isLValue As Long
    isAddressAccessor As Long
    arrayCount As Long
    arrayRank As Long
    isIncompleteArray As Long
    layoutType As String
    isLayoutArray As Long
    isAlignedArray As Long
    ' Some C array typedefs are represented by an ABI-compatible FreeBASIC
    ' record, such as jmp_buf, rather than by a FreeBASIC array declaration.
    isArrayStorageAlias As Long
    arrayElementType As String
    arrayBound As String
    ' Local C arrays flatten to row-major storage but keep dimension bounds
    ' for chained indexing and sizeof on subarrays.
    arrayDimensions As String
    arraySourceName As String
    isArrayElementZero As Long
    isPointerToArray As Long
    pointerToArrayElementCount As Long
    sizeOfArraySourceName As String
    sizeOfArrayElementSourceName As String
    sizeOfArrayCount As Long
    cRecord As String
    lValueText As String
    isWholeCall As Long
    isFunctionDesignator As Long
    ' Keep same-operator boolean chains flat so large C conditions do not
    ' become deeply nested FreeBASIC expressions.
    logicalOperator As String
    logicalCondition As String
    prelude As String
    storageType As String
    isReadOnly As Long
    bitWidth As Long
    bitOffset As Long
    bitStorageText As String
    bitFieldOwnerText As String
    bitFieldOwnerType As String
    bitFieldName As String
    bitFieldOwnerIsPointer As Long
    isDirectBitField As Long
    isPackedBitField As Long
    isUnsignedBitField As Long
    isSignedBitField As Long
End Type

Private Type SimpleExpressionParser
    sourceText As String
    position As Long
    hasBooleanOperator As Long
    hasFunctionCall As Long
    hasRuntimeValue As Long
    unevaluated As Long
    targetType As String
    ' Avoid rescanning source text at each recursive parser step.
    simpleGnuExpressionsNormalized As Long
    translation As C2fbTranslationContext Ptr
    catalog As C2fbProjectCatalog Ptr
    context As SimpleBodyContext Ptr
End Type

' Bound recursive unary operands, groups, calls, and conditional expressions.
Private Const MAX_EXPRESSION_DEPTH As Long = 128
Private Const SIMPLE_UNKNOWN_ARRAY_BOUND As String = "?"

' SQLite identifier rules consume the parser state defined above.
#include once "c2fb_sqlite_body_policy.bi"

Declare Function ParseSimpleExpressionValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal minimumPrecedence As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function TranslateSimpleAssertExpansionValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function NormalizeSimpleGnuStatementExpressions( _
    ByVal sourceText As String, ByRef normalizedText As String _
) As Long

Declare Function NormalizeSimpleGnuCallResultStatementExpressionAt( _
    ByVal sourceText As String, ByVal extensionPosition As Long, _
    ByRef normalizedExpression As String, ByRef endPosition As Long _
) As Long

Declare Function ParseSimpleObstackFinishStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function ParseSimpleObstackFreeStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Private Declare Function ParseSimpleObstackPointerGrowStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Private Declare Function ParseSimpleObstackSingleGrowStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function ParseSimpleObstackBlankStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function ParseSimpleObstackGrowStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function ParseSimpleUnaryValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function ParseSimpleCallValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue, _
    ByVal procedureName As String, ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function ParseSimpleGenericSelectionValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function SimpleIsNullValue( _
    ByRef value As SimpleExpressionValue _
) As Long

Declare Function SimpleHalfFloatValueText( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef value As SimpleExpressionValue, ByVal targetType As String _
) As String

Declare Function ParseSimpleAddressedCompoundLiteralValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function ParseSimpleArrayCompoundLiteralValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

Declare Function ParseSimpleRecordCompoundLiteralValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long

/' ------------------------------------------------------------------------- '/
/' Known arithmetic types                                                    '/
/' ------------------------------------------------------------------------- '/

' Integer codes order promoted C types by rank. Floating types are selected
' separately from integer ranks; GNU 128-bit integers follow the 64-bit types.
' The preprocessed workflow selects the host C ABI, including its long width.
Private Function SimpleArithmeticKind( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As Long
    typeName = NormalizeFbBodyType(catalog, typeName)
    If Left(typeName, 6) = "Const " Then typeName = Mid(typeName, 7)
    Select Case typeName
    Case "Byte", "UByte", "Short", "UShort", "Long", "SQLITE_C_INT", "c2fb_c_int": Return 1
    Case "ULong", "SQLITE_C_UINT", "c2fb_c_uint": Return 2
    Case "LongInt", "sqlite3_int64", "c2fb_int64": Return 3
    Case "ULongInt", "sqlite3_uint64", "c2fb_uint64": Return 4
    Case "Integer<128>": Return 8
    Case "UInteger<128>": Return 9
    Case "SQLITE_C_LONG", "CLong", "c2fb_c_long"
#if defined(__FB_64BIT__) AndAlso Not defined(__FB_WIN32__)
        Return 3
#else
        Return 1
#endif
    Case "SQLITE_C_ULONG", "CULong", "c2fb_c_ulong"
#if defined(__FB_64BIT__) AndAlso Not defined(__FB_WIN32__)
        Return 4
#else
        Return 2
#endif
    Case "Integer"
#if defined(__FB_64BIT__)
        Return 3
#else
        Return 1
#endif
    Case "SQLITE_SIZE_T", "UInteger", "c2fb_size_t"
#if defined(__FB_64BIT__)
        Return 4
#else
        Return 2
#endif
    Case "Single": Return 5
    Case "Double": Return 6
    Case "CLongDouble": Return 7
    End Select
    Return 0
End Function

Private Function SimpleArithmeticType(ByVal kind As Long) As String
    Select Case kind
    Case 1: Return "c2fb_c_int"
    Case 2: Return "c2fb_c_uint"
    Case 3: Return "c2fb_int64"
    Case 4: Return "c2fb_uint64"
    Case 5: Return "Single"
    Case 6: Return "Double"
    Case 7: Return "CLongDouble"
    Case 8: Return "Integer<128>"
    Case 9: Return "UInteger<128>"
    End Select
    Return ""
End Function

Private Function SimpleArithmeticKindIsInteger(ByVal kind As Long) As Long
    Return CInt((kind >= 1 AndAlso kind <= 4) OrElse kind = 8 OrElse kind = 9)
End Function

Private Function SimpleArithmeticKindIsFloating(ByVal kind As Long) As Long
    Return CInt(kind >= 5 AndAlso kind <= 7)
End Function

Private Function SimpleArithmeticTypeIsUnsigned( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As Long
    typeName = NormalizeFbBodyType(catalog, typeName)
    If Left(typeName, 6) = "Const " Then typeName = Mid(typeName, 7)
    Select Case typeName
    Case "UByte", "UShort", "ULong", "ULongInt", "UInteger", _
         "UInteger<128>", _
         "c2fb_c_uchar", "c2fb_c_ushort", _
         "CULong", "SQLITE_C_UINT", "SQLITE_C_ULONG", "SQLITE_SIZE_T", _
         "c2fb_c_uint", "c2fb_c_ulong", "c2fb_size_t", _
         "sqlite3_uint64", "c2fb_uint64"
        Return -1
    End Select
    Return 0
End Function

Private Function SimpleFloatingCastNeedsFix(ByVal arithmeticKind As Long) As Long
    ' C floating-to-integer casts truncate. FreeBASIC's native floating casts
    ' round; the CLongDouble cast operators already truncate in their runtime.
    Return CInt(arithmeticKind = 5 OrElse arithmeticKind = 6)
End Function

Private Function SimpleCommonArithmeticType( _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal leftType As String, ByVal rightType As String _
) As String
    Dim leftKind As Long = SimpleArithmeticKind(catalog, leftType)
    Dim rightKind As Long = SimpleArithmeticKind(catalog, rightType)
    If leftKind = 0 OrElse rightKind = 0 Then Return ""
    If SimpleArithmeticKindIsFloating(leftKind) <> 0 OrElse _
       SimpleArithmeticKindIsFloating(rightKind) <> 0 Then
        If SimpleArithmeticKindIsFloating(leftKind) = 0 Then leftKind = 0
        If SimpleArithmeticKindIsFloating(rightKind) = 0 Then rightKind = 0
    End If
    Return SimpleArithmeticType(IIf(leftKind > rightKind, leftKind, rightKind))
End Function

Private Function SimpleValueCast( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef value As SimpleExpressionValue, ByVal typeName As String _
) As String
    Dim halfFloatText As String = SimpleHalfFloatValueText( _
        translation, catalog, value, typeName)
    If halfFloatText <> "" Then Return halfFloatText
    If value.isPointerToArray <> 0 Then
        If typeName = "Any Ptr" OrElse typeName = "Const Any Ptr" Then _
            Return "CPtr(" & typeName & ", " & value.text & ")"
        If NormalizeFbBodyType(catalog, typeName) = _
           NormalizeFbBodyType(catalog, value.typeName) Then Return value.text
        Return ""
    End If
    If IsCBodyCallbackTypeInContext(translation, typeName) <> 0 Then
        If Left(Trim(value.text), Len("ProcPtr(")) = "ProcPtr(" Then Return value.text
        If SimpleIsNullValue(value) <> 0 Then Return "CPtr(" & typeName & ", 0)"
    End If
    If value.isFunctionDesignator <> 0 AndAlso _
       (typeName = "Any Ptr" OrElse InStr(typeName, " Ptr") <> 0 OrElse _
        IsCBodyCallbackTypeInContext(translation, typeName) <> 0) Then
        Return "CPtr(" & typeName & ", " & value.text & ")"
    End If
    If Len(typeName) = 0 OrElse value.typeName = typeName Then Return value.text
    If InStr(typeName, " Ptr") <> 0 OrElse IsCBodyCallbackTypeInContext(translation, typeName) <> 0 Then
        Dim sourceText As String = value.text
        Dim kind As Long = SimpleArithmeticKind(catalog, value.typeName)
        If SimpleArithmeticKindIsInteger(kind) <> 0 Then _
            sourceText = "Cast(c2fb_size_t, " & sourceText & ")"
        Return "CPtr(" & typeName & ", " & sourceText & ")"
    End If
    Dim normalizedTargetType As String = NormalizeFbBodyType(catalog, typeName)
    Dim normalizedSourceType As String = NormalizeFbBodyType(catalog, value.typeName)
    If Left(normalizedTargetType, 6) = "Const " Then _
        normalizedTargetType = Mid(normalizedTargetType, 7)
    If Left(normalizedSourceType, 6) = "Const " Then _
        normalizedSourceType = Mid(normalizedSourceType, 7)
    If normalizedTargetType = "CLongDouble" Then
        If normalizedSourceType = "CLongDouble" Then Return value.text
        Dim sourceKind As Long = SimpleArithmeticKind(catalog, value.typeName)
        Select Case sourceKind
        Case 1, 2, 3, 4
            If SimpleArithmeticTypeIsUnsigned(catalog, value.typeName) <> 0 Then
                Return "CLongDoubleFromUnsignedValue(Cast(ULongInt, " & value.text & "))"
            End If
            Return "CLongDoubleFromSignedValue(Cast(LongInt, " & value.text & "))"
        Case 5, 6
            Return "CLongDoubleFromDoubleValue(Cast(Double, " & value.text & "))"
        Case Else
            Return ""
        End Select
    End If
    Return "Cast(" & typeName & ", " & value.text & ")"
End Function

Private Function SimpleHalfFloatValueText( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef value As SimpleExpressionValue, ByVal targetType As String _
) As String
    Dim conversionName As String
    Select Case LCase(value.typeName)
    Case "c2fb_float16": conversionName = "c2fb_float16_to_single"
    Case "c2fb_bfloat16": conversionName = "c2fb_bfloat16_to_single"
    Case Else: Return ""
    End Select

    Select Case NormalizeFbBodyType(catalog, targetType)
    Case "Single": Return conversionName & "(" & value.text & ")"
    Case "Double": Return "CDbl(" & conversionName & "(" & value.text & "))"
    Case "CLongDouble"
        Return "CLongDoubleFromDoubleValue(CDbl(" & _
               conversionName & "(" & value.text & ")))"
    End Select
    Return ""
End Function

Private Function SimpleFloatingValue(ByVal expressionText As String, ByVal typeName As String) As String
    ' ast-optimize.bas reassociates floating additions and accumulates their
    ' constants, including in precise mode. A same-type CAST is discarded by
    ' ast-node-conv.bas and cannot preserve a C rounding boundary. A private
    ' value procedure keeps each operation separate and stores its C width.
    If typeName = "Single" Then Return "__c2fb_single_value(" & expressionText & ")"
    If typeName = "Double" Then Return "__c2fb_double_value(" & expressionText & ")"
    Return expressionText
End Function

Private Function SimplePointeeType(ByVal typeName As String) As String
    If Right(typeName, 4) <> " Ptr" Then Return ""
    typeName = Left(typeName, Len(typeName) - 4)
    ' Keep const when dereferencing a pointer-to-pointer. In that case the
    ' result is still a pointer to const data, and assignments to the pointer
    ' slot remain valid even though its eventual character data is read-only.
    If Left(typeName, 6) = "Const " AndAlso Right(typeName, 4) <> " Ptr" Then _
        typeName = Mid(typeName, 7)
    ' The port represents C char pointers as ZString pointers for the ABI.
    If typeName = "ZString" Then typeName = "Byte"
    Return typeName
End Function

Private Function SimpleTypePointerDepth(ByVal typeName As String) As Long
    Dim pointerDepth As Long = 0
    typeName = Trim(typeName)
    While Right(typeName, 4) = " Ptr"
        pointerDepth += 1
        typeName = Trim(Left(typeName, Len(typeName) - 4))
    Wend
    Return pointerDepth
End Function

Private Function SimpleValueHasVolatileAccess( _
    ByRef value As SimpleExpressionValue _
) As Long
    If value.isLValue = 0 OrElse value.pointerCount < 0 OrElse _
       value.pointerCount > MAX_FREEBASIC_POINTER_LEVELS OrElse _
       value.volatileMask = 0 Then Return 0
    Return CInt((value.volatileMask And (1 Shl value.pointerCount)) <> 0) * -1
End Function

Private Function SimpleValueHasVolatilePointerAccess( _
    ByRef value As SimpleExpressionValue _
) As Long
    If value.pointerCount <= 0 Then Return 0
    Return SimpleValueHasVolatileAccess(value)
End Function

Private Sub NormalizeSimpleVolatileTypedefPointer( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue _
)
    If value.isLValue = 0 OrElse value.volatileMask = 0 OrElse _
       parser.translation = 0 Then Return
    Dim resolvedPointerDepth As Long = _
        GenericFreeBasicTypePointerDepthInHeader( _
            parser.translation->genericC.header, value.typeName, 0)
    If resolvedPointerDepth <= value.pointerCount Then
        Dim callbackTypeName As String = Trim(value.typeName)
        Dim callbackPointerDepth As Long = 0
        While Right(callbackTypeName, 4) = " Ptr"
            callbackTypeName = RTrim( _
                Left(callbackTypeName, Len(callbackTypeName) - 4))
            callbackPointerDepth += 1
        Wend
        If Left(callbackTypeName, 6) = "Const " Then _
            callbackTypeName = Mid(callbackTypeName, 7)
        If IsCBodyCallbackTypeInContext( _
            parser.translation[0], callbackTypeName) <> 0 Then _
            resolvedPointerDepth = callbackPointerDepth + 1
    End If
    If resolvedPointerDepth <= value.pointerCount OrElse _
       resolvedPointerDepth > MAX_FREEBASIC_POINTER_LEVELS Then Return

    ' C qualifiers on a typedef apply to the typedef's underlying pointer
    ' levels. Shift the qualifier mask when the emitted FreeBASIC alias hides
    ' those levels, so volatile HANDLE fields use pointer access barriers.
    Dim typedefPointerDepth As Long = resolvedPointerDepth - value.pointerCount
    Dim shiftedVolatileMask As Long = 0
    For qualifierLevel As Long = 0 To MAX_FREEBASIC_POINTER_LEVELS - typedefPointerDepth
        If (value.volatileMask And (1 Shl qualifierLevel)) <> 0 Then _
            shiftedVolatileMask = shiftedVolatileMask Or _
                (1 Shl (qualifierLevel + typedefPointerDepth))
    Next
    value.pointerCount = resolvedPointerDepth
    value.volatileMask = shiftedVolatileMask
End Sub

Private Function EnsureCBodyVolatilePointerHelpers( _
    ByRef parser As SimpleExpressionParser, _
    ByRef loadName As String, ByRef storeName As String _
) As Long
    If parser.context = 0 Then
        Return 0
    End If
    loadName = "c2fb_volatile_pointer_load_" & _
        parser.context->functionName
    storeName = "c2fb_volatile_pointer_store_" & _
        parser.context->functionName
    Dim helperDeclaration As String = "Private Function " & loadName & " ("
    If InStr(parser.context->generatedBodyHelpers, helperDeclaration) = 0 Then
        parser.context->generatedBodyHelpers &= _
            "' Read C volatile pointer storage with an explicit x86 memory access." & Chr(10) & _
            "Private Function " & loadName & _
                " (ByVal address As Any Ptr) As Any Ptr" & Chr(10) & _
            "    Dim loadedValue As Any Ptr" & Chr(10) & _
            "#if defined(__FB_X86__) and defined(__FB_64BIT__)" & Chr(10) & _
            "    Asm" & Chr(10) & _
            "        mov rax, qword ptr [address]" & Chr(10) & _
            "        mov rax, qword ptr [rax]" & Chr(10) & _
            "        mov qword ptr [loadedValue], rax" & Chr(10) & _
            "    End Asm" & Chr(10) & _
            "#else" & Chr(10) & _
            "#error C2FB volatile pointer access requires x86-64" & Chr(10) & _
            "#endif" & Chr(10) & _
            "    Return loadedValue" & Chr(10) & _
            "End Function" & Chr(10) & _
            "Private Sub " & storeName & _
                " (ByVal address As Any Ptr, ByVal newValue As Any Ptr)" & Chr(10) & _
            "#if defined(__FB_X86__) and defined(__FB_64BIT__)" & Chr(10) & _
            "    Asm" & Chr(10) & _
            "        mov rax, qword ptr [address]" & Chr(10) & _
            "        mov rdx, qword ptr [newValue]" & Chr(10) & _
            "        mov qword ptr [rax], rdx" & Chr(10) & _
            "    End Asm" & Chr(10) & _
            "#else" & Chr(10) & _
            "#error C2FB volatile pointer access requires x86-64" & Chr(10) & _
            "#endif" & Chr(10) & _
            "End Sub" & Chr(10)
    End If
    Return -1
End Function

Private Function EnsureCBodyVolatileScalarHelpers( _
    ByRef parser As SimpleExpressionParser, ByVal bitWidth As Long, _
    ByRef loadName As String, ByRef storeName As String _
) As Long
    If parser.context = 0 OrElse _
       (bitWidth <> 8 AndAlso bitWidth <> 16 AndAlso _
        bitWidth <> 32 AndAlso bitWidth <> 64) Then Return 0
    loadName = "c2fb_volatile_scalar_load_" & _
        parser.context->functionName & "_" & Trim(Str(bitWidth))
    storeName = "c2fb_volatile_scalar_store_" & _
        parser.context->functionName & "_" & Trim(Str(bitWidth))
    Dim helperDeclaration As String = "Private Function " & loadName & " ("
    If InStr(parser.context->generatedBodyHelpers, helperDeclaration) = 0 Then
        Dim loadInstruction As String
        Dim storeInstruction As String
        Select Case bitWidth
        Case 8
            loadInstruction = _
                "        xor edx, edx" & Chr(10) & _
                "        mov dl, byte ptr [rax]" & Chr(10)
            storeInstruction = "        mov byte ptr [rax], dl" & Chr(10)
        Case 16
            loadInstruction = _
                "        xor edx, edx" & Chr(10) & _
                "        mov dx, word ptr [rax]" & Chr(10)
            storeInstruction = "        mov word ptr [rax], dx" & Chr(10)
        Case 32
            loadInstruction = "        mov edx, dword ptr [rax]" & Chr(10)
            storeInstruction = "        mov dword ptr [rax], edx" & Chr(10)
        Case 64
            loadInstruction = "        mov rdx, qword ptr [rax]" & Chr(10)
            storeInstruction = "        mov qword ptr [rax], rdx" & Chr(10)
        End Select
        parser.context->generatedBodyHelpers &= _
            "' Read and write volatile scalar storage with explicit width accesses." & Chr(10) & _
            "Private Function " & loadName & _
                " (ByVal address As Any Ptr) As ULongInt" & Chr(10) & _
            "    Dim loadedValue As ULongInt" & Chr(10) & _
            "#if defined(__FB_X86__) and defined(__FB_64BIT__)" & Chr(10) & _
            "    Asm" & Chr(10) & _
            "        mov rax, qword ptr [address]" & Chr(10) & _
            loadInstruction & _
            "        mov qword ptr [loadedValue], rdx" & Chr(10) & _
            "    End Asm" & Chr(10) & _
            "#else" & Chr(10) & _
            "#error C2FB volatile scalar access requires x86-64" & Chr(10) & _
            "#endif" & Chr(10) & _
            "    Return loadedValue" & Chr(10) & _
            "End Function" & Chr(10) & _
            "Private Sub " & storeName & _
                " (ByVal address As Any Ptr, ByVal newValue As ULongInt)" & Chr(10) & _
            "#if defined(__FB_X86__) and defined(__FB_64BIT__)" & Chr(10) & _
            "    Asm" & Chr(10) & _
            "        mov rax, qword ptr [address]" & Chr(10) & _
            "        mov rdx, qword ptr [newValue]" & Chr(10) & _
            storeInstruction & _
            "    End Asm" & Chr(10) & _
            "#else" & Chr(10) & _
            "#error C2FB volatile scalar access requires x86-64" & Chr(10) & _
            "#endif" & Chr(10) & _
            "End Sub" & Chr(10)
    End If
    Return -1
End Function

Private Function BuildCBodyVolatilePointerLoad( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal storageExpression As String, _
    ByRef loadExpression As String _
) As Long
    loadExpression = ""
    If SimpleValueHasVolatilePointerAccess(value) = 0 OrElse _
       value.lValueText = "" Then Return 0
    Dim loadName As String
    Dim storeName As String
    If EnsureCBodyVolatilePointerHelpers( _
        parser, loadName, storeName) = 0 Then Return 0
    loadExpression = "CPtr(" & value.typeName & ", " & loadName & _
        "(CPtr(Any Ptr, @(" & storageExpression & "))))"
    Return -1
End Function

Private Function BuildCBodyVolatilePointerStore( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal storageExpression As String, ByVal storedExpression As String, _
    ByRef storeStatement As String _
) As Long
    storeStatement = ""
    If SimpleValueHasVolatilePointerAccess(value) = 0 Then Return 0
    Dim loadName As String
    Dim storeName As String
    If EnsureCBodyVolatilePointerHelpers( _
        parser, loadName, storeName) = 0 Then Return 0
    storeStatement = storeName & "(CPtr(Any Ptr, @(" & _
        storageExpression & ")), CPtr(Any Ptr, " & storedExpression & "))"
    Return -1
End Function

Private Function BuildCBodyVolatileLoad( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal storageExpression As String, ByRef loadExpression As String _
) As Long
    loadExpression = ""
    If SimpleValueHasVolatilePointerAccess(value) <> 0 Then _
        Return BuildCBodyVolatilePointerLoad( _
            parser, value, storageExpression, loadExpression)
    If SimpleValueHasVolatileAccess(value) = 0 OrElse _
       value.pointerCount <> 0 OrElse value.lValueText = "" Then Return 0
    Dim bitWidth As Long = _
        SimpleIntegerWidthInBits(parser.catalog[0], value.typeName)
    Dim loadName As String
    Dim storeName As String
    If EnsureCBodyVolatileScalarHelpers( _
        parser, bitWidth, loadName, storeName) = 0 Then Return 0
    loadExpression = "Cast(" & value.typeName & ", " & loadName & _
        "(CPtr(Any Ptr, @(" & storageExpression & "))))"
    Return -1
End Function

Private Function BuildCBodyVolatileStore( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal storageExpression As String, ByVal storedExpression As String, _
    ByRef storeStatement As String _
) As Long
    storeStatement = ""
    If SimpleValueHasVolatilePointerAccess(value) <> 0 Then _
        Return BuildCBodyVolatilePointerStore( _
            parser, value, storageExpression, storedExpression, _
            storeStatement)
    If SimpleValueHasVolatileAccess(value) = 0 OrElse _
       value.pointerCount <> 0 Then Return 0
    Dim bitWidth As Long = _
        SimpleIntegerWidthInBits(parser.catalog[0], value.typeName)
    Dim loadName As String
    Dim storeName As String
    If EnsureCBodyVolatileScalarHelpers( _
        parser, bitWidth, loadName, storeName) = 0 Then Return 0
    storeStatement = storeName & "(CPtr(Any Ptr, @(" & _
        storageExpression & ")), Cast(ULongInt, " & storedExpression & "))"
    Return -1
End Function

Private Function SimpleArrayElementStorageType( _
    ByVal storageType As String, ByVal cPointerType As String _
) As String
    If storageType <> "Any Ptr" Then Return SimplePointeeType(storageType)

    ' An opaque Any Ptr field may represent a C pointer-to-pointer. Indexing
    ' the C value reads one pointer from the pointed-to array, so preserve the
    ' remaining C pointer depth in the pointee's FreeBASIC storage type.
    Dim pointerDepth As Long = 0
    While Right(cPointerType, 4) = " Ptr"
        pointerDepth += 1
        cPointerType = Left(cPointerType, Len(cPointerType) - 4)
    Wend
    If pointerDepth <= 1 Then Return "Any"

    Dim result As String = "Any"
    For i As Long = 1 To pointerDepth - 1
        result &= " Ptr"
    Next
    Return result
End Function

Private Function SimpleCharacterPointer(ByRef value As SimpleExpressionValue) As String
    ' A FreeBASIC ZString element is a string. CByte/CAST on it parses that
    ' string as a number, instead of reading its byte. Use a byte pointer for
    ' C indexing and dereferencing while retaining ZString at ABI boundaries.
    If value.typeName = "Const ZString Ptr" Then
        Return "CPtr(Const Byte Ptr, " & value.text & ")"
    ElseIf value.typeName = "ZString Ptr" Then
        Return "CPtr(Byte Ptr, " & value.text & ")"
    End If
    Return value.text
End Function

Private Function SimpleBooleanValue(ByVal conditionText As String) As String
    ' FreeBASIC comparisons and AndAlso/OrElse produce -1 for true. C uses a
    ' 32-bit int with value 1, including inside arithmetic and call arguments.
    ' ast-node-bop.bas in the compiler implements these boolean results.
    Return "(-Cast(c2fb_c_int, (" & conditionText & ")))"
End Function

Private Function SimpleScalarTruthCondition( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef value As SimpleExpressionValue _
) As String
    If value.typeName = "void" Then Return ""
    If InStr(value.typeName, " Ptr") <> 0 OrElse _
       IsCBodyCallbackTypeInContext(translation, value.typeName) <> 0 OrElse _
       SimpleArithmeticKind(catalog, value.typeName) > 0 Then _
        Return "(" & value.text & " <> 0)"
    Return ""
End Function

Private Function SimpleZeroIntegerExpression(ByVal sourceText As String) As Long
    sourceText = Trim(sourceText)
    While Len(sourceText) >= 2 AndAlso Left(sourceText, 1) = "(" AndAlso _
          Right(sourceText, 1) = ")"
        Dim nesting As Long = 0
        Dim enclosesWholeExpression As Long = -1
        For position As Long = 1 To Len(sourceText)
            Select Case Mid(sourceText, position, 1)
            Case "(": nesting += 1
            Case ")": nesting -= 1
            End Select
            If nesting = 0 AndAlso position < Len(sourceText) Then
                enclosesWholeExpression = 0
                Exit For
            End If
        Next
        If enclosesWholeExpression = 0 Then Exit While
        sourceText = Trim(Mid(sourceText, 2, Len(sourceText) - 2))
    Wend

    If Left(sourceText, Len("Cast(")) = "Cast(" AndAlso _
       Right(sourceText, 1) = ")" Then
        Dim nesting As Long = 0
        For position As Long = Len("Cast(") + 1 To Len(sourceText) - 1
            Select Case Mid(sourceText, position, 1)
            Case "(": nesting += 1
            Case ")": nesting -= 1
            Case ","
                If nesting = 0 Then Return SimpleZeroIntegerExpression( _
                    Mid(sourceText, position + 1, Len(sourceText) - position - 1))
            End Select
        Next
    End If

    Select Case LCase(sourceText)
    Case "0", "0u", "0l", "0ul", "0ll", "0ull", _
         "&o0", "&o0u", "&o0l", "&o0ul", "&o0ll", "&o0ull", _
         "&h0", "&h0u", "&h0l", "&h0ul", "&h0ll", "&h0ull", _
         "0x0", "0x0u", "0x0l", "0x0ul", "0x0ll", "0x0ull"
        Return -1
    End Select
    Return 0
End Function

Private Function SimpleIsNullValue(ByRef value As SimpleExpressionValue) As Long
    Dim text As String = value.text
    While Left(text, 1) = "(" AndAlso Right(text, 1) = ")"
        text = Mid(text, 2, Len(text) - 2)
    Wend
    If text = "Cast(" & value.typeName & ", &O0ULL)" OrElse _
       text = "Cast(" & value.typeName & ", 0ULL)" OrElse _
       text = "Cast(" & value.typeName & ", 0)" Then Return -1

    If Left(text, Len("CPtr(")) = "CPtr(" AndAlso Right(text, 1) = ")" Then
        Dim nesting As Long = 0
        For position As Long = Len("CPtr(") + 1 To Len(text) - 1
            Select Case Mid(text, position, 1)
            Case "(": nesting += 1
            Case ")": nesting -= 1
            Case ","
                If nesting = 0 Then Return SimpleZeroIntegerExpression( _
                    Mid(text, position + 1, Len(text) - position - 1))
            End Select
        Next
    End If
    Return 0
End Function



Declare Function CBodyProcedureCallbackTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal procedureName As String _
) As String

Private Function SimpleConditionalType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef trueValue As SimpleExpressionValue, ByRef falseValue As SimpleExpressionValue _
) As String
    If trueValue.isFunctionDesignator <> 0 AndAlso _
       falseValue.isFunctionDesignator <> 0 Then
        Dim trueCallbackType As String = CBodyProcedureCallbackTypeInContext( _
            translation, catalog, trueValue.lValueText)
        Dim falseCallbackType As String = CBodyProcedureCallbackTypeInContext( _
            translation, catalog, falseValue.lValueText)
        If trueCallbackType <> "" AndAlso falseCallbackType <> "" AndAlso _
           CBodyCallbackTypesCompatibleInContext( _
               translation, catalog, trueCallbackType, falseCallbackType, 0) <> 0 Then _
            Return trueCallbackType
        Return ""
    End If
    ' A nested conditional can leave one arm typed as a callback pointer while
    ' the other remains a C function designator. Apply function-to-pointer
    ' decay here using the known signature before joining the two arm types.
    If trueValue.isFunctionDesignator <> 0 Then
        Dim trueDesignatorCallbackType As String = _
            CBodyProcedureCallbackTypeInContext( _
                translation, catalog, trueValue.lValueText)
        If trueDesignatorCallbackType <> "" AndAlso _
           IsCBodyCallbackTypeInContext(translation, falseValue.typeName) <> 0 AndAlso _
           CBodyCallbackTypesCompatibleInContext( _
               translation, catalog, trueDesignatorCallbackType, _
               falseValue.typeName, 0) <> 0 Then Return falseValue.typeName
    End If
    If falseValue.isFunctionDesignator <> 0 Then
        Dim falseDesignatorCallbackType As String = _
            CBodyProcedureCallbackTypeInContext( _
                translation, catalog, falseValue.lValueText)
        If falseDesignatorCallbackType <> "" AndAlso _
           IsCBodyCallbackTypeInContext(translation, trueValue.typeName) <> 0 AndAlso _
           CBodyCallbackTypesCompatibleInContext( _
               translation, catalog, trueValue.typeName, _
               falseDesignatorCallbackType, 0) <> 0 Then Return trueValue.typeName
    End If
    If trueValue.typeName = falseValue.typeName Then Return trueValue.typeName
    If IsCBodyCallbackTypeInContext(translation, trueValue.typeName) <> 0 AndAlso _
       IsCBodyCallbackTypeInContext(translation, falseValue.typeName) <> 0 AndAlso _
       CBodyCallbackTypesCompatibleInContext( _
           translation, catalog, trueValue.typeName, falseValue.typeName, 0) <> 0 Then _
        Return trueValue.typeName
    Dim commonType As String = SimpleCommonArithmeticType( _
        catalog, trueValue.typeName, falseValue.typeName)
    If commonType <> "" Then Return commonType
    Dim truePointeeType As String = SimplePointeeType(trueValue.typeName)
    Dim falsePointeeType As String = SimplePointeeType(falseValue.typeName)
    If truePointeeType <> "" AndAlso falsePointeeType <> "" Then
        If trueValue.typeName = "Any Ptr" OrElse falseValue.typeName = "Any Ptr" Then
            Dim isConstPointee As Long = CInt( _
                Left(trueValue.typeName, 6) = "Const " OrElse _
                Left(falseValue.typeName, 6) = "Const ")
            Return IIf(isConstPointee <> 0, "Const Any Ptr", "Any Ptr")
        End If
        If truePointeeType = "Byte" AndAlso falsePointeeType = "Byte" AndAlso _
           (trueValue.typeName = "ZString Ptr" OrElse _
            trueValue.typeName = "Const ZString Ptr" OrElse _
            falseValue.typeName = "ZString Ptr" OrElse _
            falseValue.typeName = "Const ZString Ptr") AndAlso _
           (trueValue.typeName = "Byte Ptr" OrElse _
            trueValue.typeName = "Const Byte Ptr" OrElse _
            falseValue.typeName = "Byte Ptr" OrElse _
            falseValue.typeName = "Const Byte Ptr") Then
            Dim isConstCharacterPointer As Long = CInt( _
                Left(trueValue.typeName, 6) = "Const " OrElse _
                Left(falseValue.typeName, 6) = "Const ")
            Return IIf(isConstCharacterPointer <> 0, _
                "Const ZString Ptr", "ZString Ptr")
        End If
        If trueValue.typeName = "Const " & falseValue.typeName Then Return trueValue.typeName
        If falseValue.typeName = "Const " & trueValue.typeName Then Return falseValue.typeName
    End If
    If SimpleIsNullValue(falseValue) <> 0 AndAlso _
       (SimplePointeeType(trueValue.typeName) <> "" OrElse _
        IsCBodyCallbackTypeInContext(translation, trueValue.typeName) <> 0) Then Return trueValue.typeName
    If SimpleIsNullValue(trueValue) <> 0 AndAlso _
       (SimplePointeeType(falseValue.typeName) <> "" OrElse _
        IsCBodyCallbackTypeInContext(translation, falseValue.typeName) <> 0) Then Return falseValue.typeName
    Return ""
End Function

Private Function CBodyProcedureCallbackTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal procedureName As String _
) As String
    If procedureName = "" Then Return ""
    Dim procedureIndex As Long = _
        CBodyProcedureIndex(translation, procedureName)
    Dim returnType As String
    Dim parameterCount As Long
    Dim isVariadic As Long
    If procedureIndex >= 0 Then
        With translation.symbolTable.symbols(procedureIndex)
            If .ambiguous <> 0 OrElse .body.isAmbiguous <> 0 OrElse _
               .body.isDeclared = 0 Then Return ""
            returnType = .body.returnType
            parameterCount = .body.parameterCount
            isVariadic = .body.isVariadic
        End With
    Else
        procedureIndex = FbBodyCallSignatureIndex(catalog, procedureName)
        If procedureIndex < 0 OrElse _
           catalog.bodyCallSignatures(procedureIndex).parameterCount < 0 Then _
            Return ""
        With catalog.bodyCallSignatures(procedureIndex)
            returnType = .returnType
            parameterCount = .parameterCount
            isVariadic = .isVariadic
        End With
    End If
    If returnType = "" OrElse parameterCount < 0 OrElse _
       isVariadic <> 0 Then Return ""

    For callbackIndex As Long = 0 To translation.body.callbackCount - 1
        With translation.body.callbacks(callbackIndex)
            If .parameterCount <> parameterCount OrElse _
               .isVariadic <> isVariadic OrElse _
               CBodyCallbackTypesCompatibleInContext( _
                   translation, catalog, .returnType, returnType, 0) = 0 Then _
                Continue For
            Dim signaturesMatch As Long = -1
            For parameterIndex As Long = 0 To parameterCount - 1
                If CBodyCallbackTypesCompatibleInContext( _
                    translation, catalog, _
                    CBodyCallbackParameterTypeInContext( _
                        translation, .fbType, parameterIndex), _
                    CBodyParameterType( _
                        translation, catalog, procedureName, parameterIndex), 0) = 0 Then
                    signaturesMatch = 0
                    Exit For
                End If
            Next
            If signaturesMatch <> 0 Then Return .fbType
        End With
    Next

    Dim declaration As String = "Function CDecl("
    If returnType = "void" Then declaration = "Sub CDecl("
    Dim parameterTypes As String
    For parameterIndex As Long = 0 To parameterCount - 1
        Dim parameterType As String = CBodyParameterType( _
            translation, catalog, procedureName, parameterIndex)
        If parameterType = "" Then Return ""
        If parameterIndex > 0 Then declaration &= ", "
        declaration &= "ByVal arg" & Trim(Str(parameterIndex)) & _
                       " As " & parameterType
        parameterTypes &= parameterType & "|"
    Next
    declaration &= ")"
    If returnType <> "void" Then declaration &= " As " & returnType
    Return RegisterCBodyCallbackTypeInContext( _
        translation, catalog, declaration, returnType, parameterTypes, _
        parameterCount, isVariadic)
End Function

Private Function ScanSimpleGenericDelimiter( _
    ByVal sourceText As String, ByVal startPosition As Long, _
    ByVal scanExpression As Long, ByRef delimiterPosition As Long, _
    ByRef delimiterByte As Long _
) As Long
    Dim parentheses As Long = 0
    Dim brackets As Long = 0
    Dim braces As Long = 0
    Dim conditionalDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim position As Long = startPosition
    delimiterPosition = 0
    delimiterByte = 0

    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If quoteByte <> 0 Then
            If currentByte = Asc("\\") Then
                position += 2
                Continue While
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
        ElseIf currentByte = Asc("'") OrElse currentByte = Asc("""") Then
            quoteByte = currentByte
        ElseIf currentByte = Asc("(") Then
            parentheses += 1
        ElseIf currentByte = Asc(")") Then
            If parentheses = 0 AndAlso brackets = 0 AndAlso braces = 0 Then
                If scanExpression = 0 OrElse conditionalDepth = 0 Then
                    delimiterPosition = position
                    delimiterByte = currentByte
                    Return -1
                End If
            End If
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
            If scanExpression = 0 AndAlso currentByte = Asc(":") Then
                delimiterPosition = position
                delimiterByte = currentByte
                Return -1
            ElseIf scanExpression <> 0 Then
                If currentByte = Asc("?") Then
                    conditionalDepth += 1
                ElseIf currentByte = Asc(":") AndAlso conditionalDepth > 0 Then
                    conditionalDepth -= 1
                ElseIf conditionalDepth = 0 AndAlso _
                       (currentByte = Asc(",") OrElse currentByte = Asc(")")) Then
                    delimiterPosition = position
                    delimiterByte = currentByte
                    Return -1
                End If
            End If
        End If
        position += 1
    Wend
    Return 0
End Function

Private Function SimpleGenericAssociationType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceType As String _
) As String
    Dim typeExpression As String = "(" & Trim(sourceType) & ")0"
    Dim position As Long = 1
    Dim freeBasicType As String
    Dim isPointer As Long
    If ReadSimpleCTypeCast( _
        translation, catalog, typeExpression, position, freeBasicType, _
        isPointer) = 0 Then Return ""
    Return NormalizeFbBodyType(catalog, freeBasicType)
End Function

Private Function SimpleGenericComparableType( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As String
    typeName = NormalizeFbBodyType(catalog, typeName)
    ' C generic selection applies lvalue conversions to the controlling
    ' expression, which discard top-level scalar qualifiers.
    If Left(typeName, 6) = "Const " AndAlso InStr(typeName, " Ptr") = 0 Then _
        typeName = Mid(typeName, 7)
    Return LCase(typeName)
End Function

Private Function ParseSimpleTypeofCompoundLiteralControl( _
    ByRef parser As SimpleExpressionParser, _
    ByRef controlValue As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH Then Return 0
    Dim delimiterPosition As Long
    Dim delimiterByte As Long
    If ScanSimpleGenericDelimiter( _
        parser.sourceText, parser.position, -1, delimiterPosition, _
        delimiterByte) = 0 OrElse delimiterByte <> Asc(",") Then Return 0

    Dim controlText As String = Trim(Mid( _
        parser.sourceText, parser.position, delimiterPosition - parser.position))
    Dim castEnd As Long = 1
    SkipCSpaces(controlText, castEnd)
    If Mid(controlText, castEnd, 1) <> "(" OrElse _
       ScanSimpleExpressionGroup( _
           controlText, castEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim initializerStart As Long = castEnd
    SkipCSpaces(controlText, initializerStart)
    If Mid(controlText, initializerStart, 1) <> "{" Then Return 0
    Dim initializerEnd As Long = initializerStart
    If ScanSimpleExpressionGroup( _
        controlText, initializerEnd, Asc("{"), Asc("}")) = 0 Then Return 0
    SkipCSpaces(controlText, initializerEnd)
    If initializerEnd <= Len(controlText) Then Return 0

    Dim typeOperator As Long = InStr(controlText, "__typeof__")
    Dim typeOperatorLength As Long = Len("__typeof__")
    If typeOperator = 0 Then
        typeOperator = InStr(controlText, "typeof")
        typeOperatorLength = Len("typeof")
    End If
    If typeOperator = 0 Then Return 0
    Dim typeGroupStart As Long = typeOperator + typeOperatorLength
    SkipCSpaces(controlText, typeGroupStart)
    If Mid(controlText, typeGroupStart, 1) <> "(" Then Return 0
    Dim typeGroupEnd As Long = typeGroupStart
    If ScanSimpleExpressionGroup( _
        controlText, typeGroupEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim typeArgument As String = Trim(Mid( _
        controlText, typeGroupStart + 1, _
        typeGroupEnd - typeGroupStart - 2))
    If typeArgument = "" Then Return 0

    Dim typeName As String
    Dim typeExpression As String = "(" & typeArgument & ")0"
    Dim typeExpressionPosition As Long = 1
    Dim isPointerCast As Long
    If ReadSimpleCTypeCast( _
        parser.translation[0], parser.catalog[0], typeExpression, _
        typeExpressionPosition, typeName, isPointerCast) = 0 Then
        Dim typeofParser As SimpleExpressionParser = parser
        typeofParser.sourceText = typeArgument
        typeofParser.position = 1
        typeofParser.context = 0
        typeofParser.unevaluated = -1
        typeofParser.hasBooleanOperator = 0
        typeofParser.hasFunctionCall = 0
        Dim typeofValue As SimpleExpressionValue
        If ParseSimpleExpressionValue( _
            typeofParser, typeofValue, 2, depth + 1, callableNames(), _
            callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
            parameterCount) = 0 OrElse typeofValue.prelude <> "" Then Return 0
        typeName = typeofValue.typeName
    End If
    If typeName = "" Then Return 0
    controlValue.typeName = typeName
    controlValue.prelude = ""
    parser.position = delimiterPosition
    Return -1
End Function

Private Function ParseSimpleGenericSelectionValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH OrElse _
       Mid(parser.sourceText, parser.position, 1) <> "(" Then Return 0

    parser.position += 1
    Dim controlParser As SimpleExpressionParser = parser
    Dim controlValue As SimpleExpressionValue
    controlParser.context = 0
    controlParser.unevaluated = -1
    controlParser.hasBooleanOperator = 0
    controlParser.hasFunctionCall = 0
    Dim controlParseStart As Long = controlParser.position
    If ParseSimpleExpressionValue( _
        controlParser, controlValue, 2, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then
        controlParser.position = controlParseStart
        If ParseSimpleTypeofCompoundLiteralControl( _
            controlParser, controlValue, depth + 1, callableNames(), _
            callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
            parameterCount) = 0 Then Return 0
    End If
    SkipCSpaces(controlParser.sourceText, controlParser.position)
    If Mid(controlParser.sourceText, controlParser.position, 1) <> "," OrElse _
       controlValue.typeName = "" OrElse controlValue.prelude <> "" Then Return 0
    parser.position = controlParser.position + 1

    Dim controllingType As String = SimpleGenericComparableType( _
        parser.catalog[0], controlValue.typeName)
    If controllingType = "" Then Return 0
    Dim selectedExpression As String
    Dim defaultExpression As String
    Dim associationCount As Long = 0

    Do
        If associationCount >= 64 Then Return 0
        associationCount += 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) Then Return 0

        Dim associationType As String
        If Mid(parser.sourceText, parser.position, 7) = "default" AndAlso _
           (parser.position + 7 > Len(parser.sourceText) OrElse _
            IsIdentifierPart(Asc(parser.sourceText, parser.position + 7)) = 0) Then
            associationType = "default"
            parser.position += 7
        Else
            Dim colonPosition As Long
            Dim delimiterByte As Long
            If ScanSimpleGenericDelimiter( _
                parser.sourceText, parser.position, 0, colonPosition, _
                delimiterByte) = 0 OrElse delimiterByte <> Asc(":") Then Return 0
            associationType = Trim(Mid( _
                parser.sourceText, parser.position, colonPosition - parser.position))
            If associationType = "" Then Return 0
            parser.position = colonPosition
        End If

        SkipCSpaces(parser.sourceText, parser.position)
        If Mid(parser.sourceText, parser.position, 1) <> ":" Then Return 0
        parser.position += 1
        SkipCSpaces(parser.sourceText, parser.position)
        Dim expressionStart As Long = parser.position
        Dim boundaryPosition As Long
        Dim boundaryByte As Long
        If ScanSimpleGenericDelimiter( _
            parser.sourceText, expressionStart, -1, boundaryPosition, _
            boundaryByte) = 0 Then Return 0
        Dim associationExpression As String = Trim(Mid( _
            parser.sourceText, expressionStart, boundaryPosition - expressionStart))
        If associationExpression = "" Then Return 0

        If associationType = "default" Then
            If defaultExpression <> "" Then Return 0
            defaultExpression = associationExpression
        Else
            Dim mappedAssociationType As String = SimpleGenericAssociationType( _
                parser.translation[0], parser.catalog[0], associationType)
            If mappedAssociationType = "" Then Return 0
            If SimpleGenericComparableType( _
                parser.catalog[0], mappedAssociationType) = controllingType Then
                If selectedExpression <> "" Then Return 0
                selectedExpression = associationExpression
            End If
        End If

        parser.position = boundaryPosition
        If boundaryByte = Asc(",") Then
            parser.position += 1
        ElseIf boundaryByte = Asc(")") Then
            parser.position += 1
            Exit Do
        Else
            Return 0
        End If
    Loop

    If selectedExpression = "" Then selectedExpression = defaultExpression
    If selectedExpression = "" Then Return 0

    ' Only the selected association is evaluated. Parse it with the caller's
    ' expression state so function calls and side effects stay in that branch.
    Dim branchParser As SimpleExpressionParser = parser
    branchParser.sourceText = selectedExpression
    branchParser.position = 1
    Dim selectedValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        branchParser, selectedValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(branchParser.sourceText, branchParser.position)
    If branchParser.position <= Len(branchParser.sourceText) Then Return 0
    parser.hasBooleanOperator = branchParser.hasBooleanOperator
    parser.hasFunctionCall = branchParser.hasFunctionCall
    value = selectedValue
    Return -1
End Function

Private Function SimpleBitFieldValueText( _
    ByVal targetType As String, ByVal sourceText As String, _
    ByVal bitWidth As Long, ByVal bitOffset As Long, _
    ByVal signedness As Long _
) As String
    If bitWidth < 1 OrElse bitWidth > 32 OrElse bitOffset < 0 OrElse _
       bitOffset + bitWidth > 32 OrElse _
       signedness = C2FB_BITFIELD_SIGNEDNESS_UNKNOWN Then Return ""

    Dim bitMask As ULongInt = &HFFFFFFFFULL
    If bitWidth < 32 Then bitMask = (&H1ULL Shl bitWidth) - 1
    Dim bitMaskText As String = "&H" & Hex(bitMask) & "ULL"
    Dim bitsText As String = "Cast(c2fb_c_uint, " & sourceText & ")"
    If bitOffset > 0 Then _
        bitsText = "(" & bitsText & " Shr " & Trim(Str(bitOffset)) & ")"
    bitsText = "(" & bitsText & " And Cast(c2fb_c_uint, " & bitMaskText & "))"

    If signedness = C2FB_BITFIELD_SIGNEDNESS_SIGNED Then
        ' The xor maps a signed width's range into a non-negative range. Widen
        ' before subtracting so sign extension never depends on an out-of-range
        ' unsigned-to-signed 32-bit cast.
        Dim signMask As ULongInt = &H1ULL Shl (bitWidth - 1)
        Dim signMaskText As String = "&H" & Hex(signMask) & "ULL"
        Dim signMaskDecimal As String = Trim(Str(signMask)) & "LL"
        Dim signedValue As String = "(Cast(LongInt, (" & bitsText & _
            " Xor Cast(c2fb_c_uint, " & signMaskText & "))) - " & _
            signMaskDecimal & ")"
        Return "Cast(" & targetType & ", " & signedValue & ")"
    End If

    Return "Cast(" & targetType & ", " & bitsText & ")"
End Function

Private Function SimpleBitFieldStoredValues( _
    ByRef parser As SimpleExpressionParser, ByVal targetType As String, _
    ByVal storageType As String, ByVal isPackedBitField As Long, _
    ByVal isSignedBitField As Long, ByVal isUnsignedBitField As Long, _
    ByVal bitWidth As Long, ByVal bitOffset As Long, _
    ByVal storage As String, ByVal assignedText As String, _
    ByRef valueForStorage As String, ByRef valueAfterStorage As String _
) As Long
    If (isSignedBitField = 0 AndAlso isUnsignedBitField = 0) OrElse _
       SimpleArithmeticKind(parser.catalog[0], targetType) = 0 OrElse _
       bitWidth < 1 OrElse bitWidth > 32 Then Return 0

    Dim bitMask As ULongInt = &HFFFFFFFFULL
    If bitWidth < 32 Then bitMask = (&H1ULL Shl bitWidth) - 1
    Dim bitMaskText As String = "&H" & Hex(bitMask) & "ULL"
    Dim maskedValue As String = "(Cast(c2fb_c_uint, " & assignedText & _
        ") And Cast(c2fb_c_uint, " & bitMaskText & "))"
    Dim bitfieldSignedness As Long = C2FB_BITFIELD_SIGNEDNESS_UNSIGNED
    If isSignedBitField <> 0 Then _
        bitfieldSignedness = C2FB_BITFIELD_SIGNEDNESS_SIGNED
    valueAfterStorage = SimpleBitFieldValueText( _
        targetType, maskedValue, bitWidth, 0, bitfieldSignedness)
    If valueAfterStorage = "" Then Return 0

    If isPackedBitField <> 0 Then
        If bitOffset < 0 OrElse bitOffset + bitWidth > 32 Then Return 0
        Dim shiftedMask As ULongInt = bitMask Shl bitOffset
        Dim shiftedMaskText As String = "&H" & Hex(shiftedMask) & "ULL"
        Dim shiftedValue As String = "(" & maskedValue & " Shl " & _
            Trim(Str(bitOffset)) & ")"
        valueForStorage = "((Cast(c2fb_c_uint, " & storage & ") And " & _
            "Not(Cast(c2fb_c_uint, " & shiftedMaskText & "))) Or " & _
            shiftedValue & ")"
        If storageType <> "" Then _
            valueForStorage = "Cast(" & storageType & ", " & valueForStorage & ")"
    ElseIf storageType <> "" Then
        valueForStorage = "Cast(" & storageType & ", " & maskedValue & ")"
    Else
        valueForStorage = maskedValue
    End If
    Return -1
End Function

/' ------------------------------------------------------------------------- '/
/' Literal scanning                                                          '/
/' ------------------------------------------------------------------------- '/

' Literal and sequence passes share the expression parser's private models.
#include once "c2fb_literals.bi"
#include once "c2fb_sequence.bi"

Private Function CBodyBuiltinByteSwapExpression( _
    ByVal procedureName As String, ByVal argumentText As String _
) As String
    Dim resultType As String = CBodyBuiltinType(procedureName)
    Dim workingType As String
    Dim byteCount As Long
    Select Case procedureName
    Case "__builtin_bswap16"
        workingType = "ULong"
        byteCount = 2
    Case "__builtin_bswap32"
        workingType = "ULong"
        byteCount = 4
    Case "__builtin_bswap64"
        workingType = "ULongInt"
        byteCount = 8
    Case Else
        Return ""
    End Select

    Dim valueText As String = "Cast(" & workingType & ", Cast(" & _
        resultType & ", " & argumentText & "))"
    Dim swappedBytes As String
    ' Reverse each byte by masking and shifting its value. This avoids reading
    ' the integer through a byte pointer, which would depend on host endianness.
    For sourceByte As Long = 0 To byteCount - 1
        Dim sourceShift As Long = sourceByte * 8
        Dim targetShift As Long = (byteCount - sourceByte - 1) * 8
        Dim byteMask As String = "Cast(" & workingType & ", &HFF)"
        If sourceShift > 0 Then _
            byteMask = "(" & byteMask & " Shl " & Trim(Str(sourceShift)) & ")"
        Dim byteValue As String = "(" & valueText & " And " & byteMask & ")"
        If targetShift > sourceShift Then
            byteValue = "(" & byteValue & " Shl " & _
                Trim(Str(targetShift - sourceShift)) & ")"
        ElseIf sourceShift > targetShift Then
            byteValue = "(" & byteValue & " Shr " & _
                Trim(Str(sourceShift - targetShift)) & ")"
        End If
        If swappedBytes <> "" Then swappedBytes &= " Or "
        swappedBytes &= byteValue
    Next
    Return "Cast(" & resultType & ", (" & swappedBytes & "))"
End Function

Private Function CBodyBuiltinInfinityExpression( _
    ByVal procedureName As String _
) As String
    Select Case procedureName
    Case "__builtin_huge_val", "__builtin_inf"
        Return "Cast(Double, INFINITY)"
    Case "__builtin_huge_valf", "__builtin_inff"
        Return "HUGE_VALF"
    End Select
    Return ""
End Function

Private Function CBodyBuiltinCheckedOverflowKind( _
    ByVal procedureName As String _
) As Long
    Select Case procedureName
    Case "__builtin_add_overflow": Return 1
    Case "__builtin_sub_overflow": Return 2
    Case "__builtin_mul_overflow": Return 3
    End Select
    Return 0
End Function

Private Function CBodyBuiltinCheckedOverflowPredicateKind( _
    ByVal procedureName As String _
) As Long
    Select Case procedureName
    Case "__builtin_add_overflow_p": Return 1
    Case "__builtin_sub_overflow_p": Return 2
    Case "__builtin_mul_overflow_p": Return 3
    End Select
    Return 0
End Function

Private Function SimpleIntegerWidthInBits( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As Long
    typeName = NormalizeFbBodyType(catalog, typeName)
    If Left(typeName, 6) = "Const " Then typeName = Mid(typeName, 7)
    Select Case typeName
    Case "Byte", "UByte", "c2fb_c_char", "c2fb_c_uchar": Return 8
    Case "Short", "UShort", "c2fb_c_short", "c2fb_c_ushort": Return 16
    End Select
    Dim arithmeticKind As Long = SimpleArithmeticKind(catalog, typeName)
    Select Case arithmeticKind
    Case 1, 2: Return 32
    Case 3, 4: Return 64
    Case 8, 9: Return 128
    End Select
    Return 0
End Function

Private Function CBodyGeneratedExpressionUsesRuntimeStorage( _
    ByVal expressionText As String _
) As Long
    Dim position As Long = 1
    While position <= Len(expressionText)
        If IsIdentifierStart(Asc(expressionText, position)) = 0 Then
            position += 1
            Continue While
        End If
        Dim tokenStart As Long = position
        position += 1
        While position <= Len(expressionText) AndAlso _
              IsIdentifierPart(Asc(expressionText, position)) <> 0
            position += 1
        Wend
        Dim token As String = Mid( _
            expressionText, tokenStart, position - tokenStart)
        If Left(token, 5) = "local" OrElse Left(token, 3) = "arg" OrElse _
           Left(token, 10) = "c2fb_temp_" OrElse _
           Left(token, 15) = "c2fb_external_" OrElse _
           Left(token, 12) = "c2fb_global_" Then Return -1
    Wend
    Return 0
End Function

Private Function CBodyBuiltinConstantPUsesRuntimeValue( _
    ByRef parser As SimpleExpressionParser, _
    ByVal sourceExpression As String, ByVal freeBasicExpression As String, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    ByVal parameterCount As Long _
) As Long
    If CBodyGeneratedExpressionUsesRuntimeStorage( _
        freeBasicExpression) <> 0 Then Return -1

    Dim position As Long = 1
    While position <= Len(sourceExpression)
        If IsIdentifierStart(Asc(sourceExpression, position)) = 0 Then
            position += 1
            Continue While
        End If
        Dim tokenStart As Long = position
        position += 1
        While position <= Len(sourceExpression) AndAlso _
              IsIdentifierPart(Asc(sourceExpression, position)) <> 0
            position += 1
        Wend
        Dim identifier As String = Mid( _
            sourceExpression, tokenStart, position - tokenStart)
        If ParameterAlias( _
            parameterNames(), parameterAliases(), parameterCount, identifier) <> "" OrElse _
           CBodyExternalObjectIndex( _
               parser.translation[0], identifier) >= 0 OrElse _
           CBodyProcedureIndex( _
               parser.translation[0], identifier) >= 0 OrElse _
           C2fbNameListContains( _
               callableNames(), callableCount, identifier) <> 0 Then Return -1
    Wend
    Return 0
End Function

Private Function LowerCBodyBuiltinConstantPCall( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, arguments() As SimpleExpressionValue, _
    argumentSourceTexts() As String, ByVal argumentCount As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    ByVal parameterCount As Long _
) As Long
    If argumentCount <> 1 Then Return 0
    Dim constantValue As Long
    Dim resultValue As Long
    If EvaluateGenericEnumIntegerValue( _
        parser.translation[0], argumentSourceTexts(0), constantValue) <> 0 Then
        resultValue = -1
    ElseIf arguments(0).isLValue <> 0 OrElse _
           arguments(0).isWholeCall <> 0 OrElse _
           arguments(0).prelude <> "" OrElse _
           CBodyBuiltinConstantPUsesRuntimeValue( _
               parser, argumentSourceTexts(0), arguments(0).text, _
               callableNames(), callableCount, parameterNames(), _
               parameterAliases(), parameterCount) <> 0 Then
        resultValue = 0
    Else
        Return 0
    End If

    value.text = IIf(resultValue <> 0, "1", "0")
    value.typeName = "c2fb_c_int"
    value.layoutType = value.typeName
    value.storageType = value.typeName
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.isReadOnly = 0
    value.lValueText = ""
    value.isWholeCall = 0
    value.isFunctionDesignator = 0
    value.arrayCount = 0
    value.arrayBound = ""
    value.arrayElementType = ""
    Return -1
End Function

Private Function LowerCBodyStdBitCountCall( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, arguments() As SimpleExpressionValue, _
    ByVal argumentCount As Long, ByVal operationKind As Long _
) As Long
    If argumentCount <> 1 Then Return 0

    Dim argumentType As String = arguments(0).typeName
    Dim bitWidth As Long
    If operationKind = 5 OrElse operationKind = 8 Then
        bitWidth = 32
    ElseIf operationKind = 6 OrElse operationKind = 9 Then
        bitWidth = SimpleIntegerWidthInBits( _
            parser.catalog[0], "c2fb_c_long")
    ElseIf operationKind = 7 OrElse operationKind = 10 Then
        bitWidth = 64
    Else
        bitWidth = SimpleIntegerWidthInBits( _
            parser.catalog[0], argumentType)
        If SimpleArithmeticTypeIsUnsigned( _
            parser.catalog[0], argumentType) = 0 Then Return 0
    End If
    Dim arithmeticKind As Long = _
        SimpleArithmeticKind(parser.catalog[0], argumentType)
    If bitWidth < 8 OrElse bitWidth > 64 OrElse _
       arithmeticKind < 1 OrElse arithmeticKind > 4 Then Return 0

    Dim resultType As String = IIf( _
        operationKind = 3 OrElse operationKind >= 5, _
        "c2fb_c_int", "c2fb_c_uint")
    value.typeName = resultType
    value.layoutType = value.typeName
    value.storageType = value.typeName
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.isReadOnly = 0
    value.lValueText = ""
    value.isWholeCall = 0
    value.isFunctionDesignator = 0
    value.arrayCount = 0
    value.arrayBound = ""
    value.arrayElementType = ""
    If parser.unevaluated <> 0 Then
        value.text = "0"
        Return -1
    End If
    If parser.context = 0 OrElse _
       FreezeSimpleValue(parser, arguments(0)) = 0 Then Return 0
    value.prelude &= arguments(0).prelude

    Dim operationName As String
    If operationKind = 1 OrElse operationKind = 3 Then
        operationName = "leading_zeros"
    ElseIf operationKind = 2 OrElse operationKind >= 8 Then
        operationName = "trailing_zeros"
    ElseIf operationKind = 4 Then
        operationName = "bit_width"
    ElseIf operationKind >= 5 AndAlso operationKind <= 7 Then
        operationName = "popcount"
    Else
        Return 0
    End If
    Dim zeroResult As String = Trim(Str(bitWidth))
    If operationKind = 4 Then zeroResult = "0"
    If operationKind >= 5 Then zeroResult = "0"
    Dim baseHelperName As String = "c2fb_builtin_stdc_" & _
        operationName & "_" & Trim(Str(bitWidth))
    If operationKind = 3 OrElse operationKind >= 8 Then _
        baseHelperName &= "_int"
    Dim helperName As String = baseHelperName
    Dim helperStart As Long = InStr( _
        parser.context->generatedBodyHelpers, _
        "Private Function " & baseHelperName)
    If helperStart > 0 Then
        Dim helperNameStart As Long = helperStart + Len("Private Function ")
        Dim helperNameEnd As Long = InStr( _
            helperNameStart, parser.context->generatedBodyHelpers, " (")
        If helperNameEnd = 0 Then Return 0
        helperName = Mid( _
            parser.context->generatedBodyHelpers, helperNameStart, _
            helperNameEnd - helperNameStart)
    Else
        Dim serial As Long = _
            parser.translation[0].body.generatedAggregateInitializerSerial
        Do
            helperName = baseHelperName & "_" & Trim(Str(serial))
            serial += 1
        Loop While CBodyProcedureIndex( _
            parser.translation[0], helperName) >= 0 OrElse _
            CBodyExternalObjectIndex(parser.translation[0], helperName) >= 0
        parser.translation[0].body.generatedAggregateInitializerSerial = serial

        Dim helperText As String = _
            "' Bit-count helper for a fixed-width unsigned value" & Chr(10) & _
            "Private Function " & helperName & _
            " (ByVal c2fb_value As ULongInt) As " & resultType & Chr(10) & _
            "    If c2fb_value = 0 Then Return " & _
                zeroResult & Chr(10) & _
            "    Dim c2fb_count As c2fb_c_uint = 0" & Chr(10)
        If operationKind = 4 Then
            helperText &= _
                "    While c2fb_value <> 0" & Chr(10) & _
                "        c2fb_count += 1" & Chr(10) & _
                "        c2fb_value Shr= 1" & Chr(10) & _
                "    Wend" & Chr(10)
        ElseIf operationKind = 1 OrElse operationKind = 3 Then
            helperText &= _
                "    Dim c2fb_mask As ULongInt = " & _
                    "Cast(ULongInt, 1) Shl " & Trim(Str(bitWidth - 1)) & Chr(10) & _
                "    While (c2fb_value And c2fb_mask) = 0" & Chr(10) & _
                "        c2fb_count += 1" & Chr(10) & _
                "        c2fb_mask Shr= 1" & Chr(10) & _
                "    Wend" & Chr(10)
        ElseIf operationKind >= 5 AndAlso operationKind <= 7 Then
            helperText &= _
                "    While c2fb_value <> 0" & Chr(10) & _
                "        If (c2fb_value And 1ULL) <> 0 Then " & _
                    "c2fb_count += 1" & Chr(10) & _
                "        c2fb_value Shr= 1" & Chr(10) & _
                "    Wend" & Chr(10)
        Else
            helperText &= _
                "    While (c2fb_value And Cast(ULongInt, 1)) = 0" & Chr(10) & _
                "        c2fb_count += 1" & Chr(10) & _
                "        c2fb_value Shr= 1" & Chr(10) & _
                "    Wend" & Chr(10)
        End If
        helperText &= _
            "    Return c2fb_count" & Chr(10) & _
            "End Function" & Chr(10) & Chr(10)
        parser.context->generatedBodyHelpers &= helperText
    End If

    Dim argumentBits As String = "Cast(ULongInt, " & arguments(0).text & ")"
    If operationKind >= 5 AndAlso bitWidth < 64 Then
        Dim argumentMask As String
        Select Case bitWidth
        Case 8: argumentMask = "255"
        Case 16: argumentMask = "65535"
        Case 32: argumentMask = "4294967295"
        Case Else: Return 0
        End Select
        argumentBits = "(" & argumentBits & " And " & _
            argumentMask & "ULL)"
    End If
    value.text = helperName & "(" & argumentBits & ")"
    Return -1
End Function

Private Function LowerCBodyStdRotateCall( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, arguments() As SimpleExpressionValue, _
    ByVal argumentCount As Long, ByVal operationKind As Long _
) As Long
    If argumentCount <> 2 OrElse parser.context = 0 Then Return 0
    If arguments(0).bitWidth >= 0 OrElse arguments(1).bitWidth >= 0 OrElse _
       arguments(0).isDirectBitField <> 0 OrElse _
       arguments(1).isDirectBitField <> 0 OrElse _
       arguments(0).isPackedBitField <> 0 OrElse _
       arguments(1).isPackedBitField <> 0 Then Return 0

    Dim resultType As String = arguments(0).typeName
    If Left(resultType, 6) = "Const " Then resultType = Mid(resultType, 7)
    Dim bitWidth As Long = _
        SimpleIntegerWidthInBits(parser.catalog[0], resultType)
    If bitWidth < 8 OrElse bitWidth > 64 OrElse _
       SimpleArithmeticTypeIsUnsigned(parser.catalog[0], resultType) = 0 OrElse _
       SimpleIntegerWidthInBits( _
           parser.catalog[0], arguments(1).typeName) = 0 Then Return 0

    value.typeName = resultType
    value.layoutType = resultType
    value.storageType = resultType
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.isReadOnly = 0
    value.lValueText = ""
    value.isWholeCall = 0
    value.isFunctionDesignator = 0
    value.arrayCount = 0
    value.arrayBound = ""
    value.arrayElementType = ""
    value.bitWidth = -1
    value.isDirectBitField = 0
    value.isPackedBitField = 0
    value.isSignedBitField = 0
    value.isUnsignedBitField = 0
    If parser.unevaluated <> 0 Then
        value.text = "0"
        Return -1
    End If

    For argumentIndex As Long = 0 To 1
        If FreezeSimpleValue(parser, arguments(argumentIndex)) = 0 Then Return 0
        value.prelude &= arguments(argumentIndex).prelude
    Next

    Dim valueBits As String = NewSimpleTemporary(parser, "ULongInt")
    Dim rotationCount As String = NewSimpleTemporary(parser, "ULongInt")
    Dim resultBits As String = NewSimpleTemporary(parser, "ULongInt")
    If valueBits = "" OrElse rotationCount = "" OrElse resultBits = "" Then _
        Return 0

    value.prelude &= valueBits & " = Cast(ULongInt, " & _
        arguments(0).text & ")" & Chr(10)
    value.prelude &= rotationCount & " = Cast(ULongInt, " & _
        arguments(1).text & ") Mod " & Trim(Str(bitWidth)) & Chr(10)
    value.prelude &= resultBits & " = " & valueBits & Chr(10)
    If operationKind = 1 Then
        value.prelude &= "If " & rotationCount & " <> 0 Then" & Chr(10) & _
            "    " & resultBits & " = (" & valueBits & " Shl " & _
            rotationCount & ") Or (" & valueBits & " Shr (" & _
            Trim(Str(bitWidth)) & " - " & rotationCount & "))" & Chr(10) & _
            "End If" & Chr(10)
    ElseIf operationKind = 2 Then
        value.prelude &= "If " & rotationCount & " <> 0 Then" & Chr(10) & _
            "    " & resultBits & " = (" & valueBits & " Shr " & _
            rotationCount & ") Or (" & valueBits & " Shl (" & _
            Trim(Str(bitWidth)) & " - " & rotationCount & "))" & Chr(10) & _
            "End If" & Chr(10)
    Else
        Return 0
    End If

    ' Rotations run in an unsigned 64-bit temporary; keep only the source width.
    Select Case bitWidth
    Case 8: value.prelude &= resultBits & " = " & resultBits & " And 255ULL" & Chr(10)
    Case 16: value.prelude &= resultBits & " = " & resultBits & " And 65535ULL" & Chr(10)
    Case 32
        value.prelude &= resultBits & " = " & resultBits & _
            " And 4294967295ULL" & Chr(10)
    End Select
    value.text = "Cast(" & resultType & ", " & resultBits & ")"
    Return -1
End Function

Private Function CBodyBuiltinCpuFeatureKind( _
    ByVal sourceArgument As String _
) As Long
    sourceArgument = Trim(sourceArgument)
    While Len(sourceArgument) >= 2 AndAlso _
          Left(sourceArgument, 1) = "(" AndAlso _
          Right(sourceArgument, 1) = ")"
        Dim groupEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceArgument, groupEnd, Asc("("), Asc(")")) = 0 OrElse _
           groupEnd <> Len(sourceArgument) + 1 Then Exit While
        sourceArgument = Trim(Mid( _
            sourceArgument, 2, Len(sourceArgument) - 2))
    Wend
    If Len(sourceArgument) < 2 OrElse _
       Left(sourceArgument, 1) <> Chr(34) OrElse _
       Right(sourceArgument, 1) <> Chr(34) Then Return 0
    Dim featureName As String = Mid(sourceArgument, 2, Len(sourceArgument) - 2)
    If InStr(featureName, Chr(92)) <> 0 Then Return 0
    Select Case featureName
    Case "avx": Return 1
    Case "avx2": Return 2
    Case "avx512f": Return 3
    Case "avx512bw": Return 4
    Case "pclmul": Return 5
    Case "vpclmulqdq": Return 6
    End Select
    Return 0
End Function

Private Function LowerCBodyBuiltinCpuSupportsCall( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, arguments() As SimpleExpressionValue, _
    argumentSourceTexts() As String, ByVal argumentCount As Long _
) As Long
    If argumentCount <> 1 OrElse parser.context = 0 Then Return 0
    value.typeName = "c2fb_c_int"
    value.layoutType = value.typeName
    value.storageType = value.typeName
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.lValueText = ""
    value.isWholeCall = 0
    value.isFunctionDesignator = 0
    value.arrayCount = 0
    value.arrayBound = ""
    value.arrayElementType = ""
    If parser.unevaluated <> 0 Then
        value.text = "0"
        Return -1
    End If
    If arguments(0).prelude <> "" OrElse _
       Right(arguments(0).typeName, 4) <> " Ptr" Then Return 0
    Dim featureKind As Long = CBodyBuiltinCpuFeatureKind( _
        argumentSourceTexts(0))
    If featureKind = 0 Then Return 0

    Dim helperName As String = "c2fb_cpu_features_" & _
        parser.context->functionName
    Dim helperDeclaration As String = "Private Function " & helperName & " ("
    If InStr(parser.context->generatedBodyHelpers, helperDeclaration) = 0 Then
        Dim helperText As String = _
            "' Runtime x86 feature check used for C __builtin_cpu_supports." & Chr(10) & _
            "Private Function " & helperName & _
                " (ByVal featureKind As Long) As Long" & Chr(10) & _
            "#if defined(__FB_X86__) and defined(__FB_64BIT__)" & Chr(10) & _
            "    Dim maximumLeaf As UInteger = 0" & Chr(10) & _
            "    Dim leaf1Ecx As UInteger = 0" & Chr(10) & _
            "    Dim leaf7Ebx As UInteger = 0" & Chr(10) & _
            "    Dim leaf7Ecx As UInteger = 0" & Chr(10) & _
            "    Dim xcr0Low As UInteger = 0" & Chr(10) & _
            "    Asm" & Chr(10) & _
            "        push rbx" & Chr(10) & _
            "        xor eax, eax" & Chr(10) & _
            "        xor ecx, ecx" & Chr(10) & _
            "        cpuid" & Chr(10) & _
            "        mov dword ptr [maximumLeaf], eax" & Chr(10) & _
            "        mov eax, 1" & Chr(10) & _
            "        xor ecx, ecx" & Chr(10) & _
            "        cpuid" & Chr(10) & _
            "        mov dword ptr [leaf1Ecx], ecx" & Chr(10) & _
            "        pop rbx" & Chr(10) & _
            "    End Asm" & Chr(10) & _
            "    Dim avxAvailable As Long = 0" & Chr(10) & _
            "    Dim avx512StateAvailable As Long = 0" & Chr(10) & _
            "    If maximumLeaf >= 7 Then" & Chr(10) & _
            "        Asm" & Chr(10) & _
            "            push rbx" & Chr(10) & _
            "            mov eax, 7" & Chr(10) & _
            "            xor ecx, ecx" & Chr(10) & _
            "            cpuid" & Chr(10) & _
            "            mov dword ptr [leaf7Ebx], ebx" & Chr(10) & _
            "            mov dword ptr [leaf7Ecx], ecx" & Chr(10) & _
            "            pop rbx" & Chr(10) & _
            "    End Asm" & Chr(10) & _
            "    End If" & Chr(10) & _
            "    ' OSXSAVE and AVX are CPUID leaf 1 ECX bits 26 through 28." & Chr(10) & _
            "    If (leaf1Ecx And &H1C000000) = &H1C000000 Then" & Chr(10) & _
            "        Asm" & Chr(10) & _
            "            xor ecx, ecx" & Chr(10) & _
            "            xgetbv" & Chr(10) & _
            "            mov dword ptr [xcr0Low], eax" & Chr(10) & _
            "        End Asm" & Chr(10) & _
            "        If (xcr0Low And &H6) = &H6 Then avxAvailable = 1" & Chr(10) & _
            "        If (xcr0Low And &HE6) = &HE6 Then" & Chr(10) & _
            "            avx512StateAvailable = 1" & Chr(10) & _
            "        End If" & Chr(10) & _
            "    End If" & Chr(10) & _
            "    Select Case featureKind" & Chr(10) & _
            "    Case 1" & Chr(10) & _
            "        Return avxAvailable" & Chr(10) & _
            "    Case 2" & Chr(10) & _
            "        If avxAvailable <> 0 AndAlso (leaf7Ebx And &H20) <> 0 Then Return 1" & Chr(10) & _
            "    Case 3" & Chr(10) & _
            "        If avx512StateAvailable <> 0 AndAlso (leaf7Ebx And &H10000) <> 0 Then Return 1" & Chr(10) & _
            "    Case 4" & Chr(10) & _
            "        If avx512StateAvailable <> 0 AndAlso (leaf7Ebx And &H40000000) <> 0 Then Return 1" & Chr(10) & _
            "    Case 5" & Chr(10) & _
            "        If (leaf1Ecx And &H2) <> 0 Then Return 1" & Chr(10) & _
            "    Case 6" & Chr(10) & _
            "        If avxAvailable <> 0 AndAlso (leaf7Ecx And &H400) <> 0 Then Return 1" & Chr(10) & _
            "    End Select" & Chr(10) & _
            "#endif" & Chr(10) & _
            "    Return 0" & Chr(10) & _
            "End Function" & Chr(10)
        parser.context->generatedBodyHelpers &= helperText
    End If
    value.text = helperName & "(" & Trim(Str(featureKind)) & ")"
    value.prelude = arguments(0).prelude
    Return -1
End Function

Private Function LowerCBodyUnsignedCheckedOverflowCall( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, arguments() As SimpleExpressionValue, _
    ByVal operationKind As Long, ByVal resultType As String, _
    ByVal resultWidth As Long _
) As Long
    Dim maximumValue As String
    Select Case resultWidth
    Case 8: maximumValue = "255ULL"
    Case 16: maximumValue = "65535ULL"
    Case 32: maximumValue = "4294967295ULL"
    Case 64: maximumValue = "18446744073709551615ULL"
    Case Else: Return 0
    End Select

    Dim leftValue As String = NewSimpleTemporary(parser, "ULongInt")
    Dim rightValue As String = NewSimpleTemporary(parser, "ULongInt")
    Dim resultBits As String = NewSimpleTemporary(parser, "ULongInt")
    Dim overflowFlag As String = NewSimpleTemporary(parser, "c2fb_c_int")
    Dim convertedValue As String = NewSimpleTemporary(parser, resultType)
    If leftValue = "" OrElse rightValue = "" OrElse resultBits = "" OrElse _
       overflowFlag = "" OrElse convertedValue = "" Then Return 0

    value.prelude &= leftValue & " = Cast(ULongInt, " & _
        arguments(0).text & ")" & Chr(10)
    value.prelude &= rightValue & " = Cast(ULongInt, " & _
        arguments(1).text & ")" & Chr(10)
    value.prelude &= overflowFlag & " = 0" & Chr(10)

    Select Case operationKind
    Case 1
        ' Compare before addition so 64-bit unsigned overflow never occurs in
        ' the check itself. Narrow outputs also reject oversized operands.
        value.prelude &= "If " & rightValue & " > " & maximumValue & _
            " OrElse " & leftValue & " > " & maximumValue & _
            " OrElse " & leftValue & " > (" & maximumValue & " - " & _
            rightValue & ") Then" & Chr(10) & _
            "    " & overflowFlag & " = 1" & Chr(10) & "End If" & Chr(10)
        value.prelude &= resultBits & " = " & leftValue & " + " & _
            rightValue & Chr(10)
    Case 2
        value.prelude &= resultBits & " = " & leftValue & " - " & _
            rightValue & Chr(10)
        value.prelude &= "If " & leftValue & " < " & rightValue & _
            " OrElse " & resultBits & " > " & maximumValue & " Then" & Chr(10) & _
            "    " & overflowFlag & " = 1" & Chr(10) & "End If" & Chr(10)
    Case 3
        value.prelude &= "If " & rightValue & " <> 0 Then" & Chr(10) & _
            "    If " & leftValue & " > (" & maximumValue & " \ " & _
            rightValue & ") Then" & Chr(10) & _
            "        " & overflowFlag & " = 1" & Chr(10) & _
            "    End If" & Chr(10) & "End If" & Chr(10)
        value.prelude &= resultBits & " = " & leftValue & " * " & _
            rightValue & Chr(10)
    Case Else
        Return 0
    End Select

    If resultWidth < 64 Then _
        value.prelude &= resultBits & " = " & resultBits & " And " & _
            maximumValue & Chr(10)
    value.prelude &= convertedValue & " = Cast(" & resultType & ", " & _
        resultBits & ")" & Chr(10)
    value.prelude &= "CPtr(" & resultType & " Ptr, " & arguments(2).text & _
        ")[0] = " & convertedValue & Chr(10)
    value.text = overflowFlag
    value.typeName = "c2fb_c_int"
    value.layoutType = value.typeName
    value.storageType = value.typeName
    value.cRecord = ""
    value.isLValue = 0
    value.isFunctionDesignator = 0
    value.lValueText = ""
    value.isWholeCall = 0
    value.arrayCount = 0
    value.arrayBound = ""
    value.arrayElementType = ""
    Return -1
End Function

Private Function LowerCBodyCheckedOverflowCall( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, arguments() As SimpleExpressionValue, _
    ByVal argumentCount As Long, ByVal operationKind As Long _
) As Long
    If argumentCount <> 3 OrElse parser.context = 0 Then Return 0
    Dim resultType As String = SimplePointeeType(arguments(2).typeName)
    Dim resultWidth As Long = _
        SimpleIntegerWidthInBits(parser.catalog[0], resultType)
    If resultType = "" OrElse resultWidth = 0 OrElse _
       SimpleIntegerWidthInBits( _
           parser.catalog[0], arguments(0).typeName) = 0 OrElse _
       SimpleIntegerWidthInBits( _
           parser.catalog[0], arguments(1).typeName) = 0 Then Return 0
    If Left(resultType, 6) = "Const " Then Return 0

    If parser.unevaluated <> 0 Then
        value.text = "0"
        value.typeName = "c2fb_c_int"
        value.layoutType = value.typeName
        value.storageType = value.typeName
        value.isLValue = 0
        value.isFunctionDesignator = 0
        Return -1
    End If

    For argumentIndex As Long = 0 To 2
        If FreezeSimpleValue(parser, arguments(argumentIndex)) = 0 Then Return 0
        value.prelude &= arguments(argumentIndex).prelude
    Next

    Dim overflowIsUnsigned As Long = CInt( _
        SimpleArithmeticTypeIsUnsigned(parser.catalog[0], resultType) <> 0)
    If overflowIsUnsigned <> 0 AndAlso _
       SimpleArithmeticTypeIsUnsigned( _
           parser.catalog[0], arguments(0).typeName) <> 0 AndAlso _
       SimpleArithmeticTypeIsUnsigned( _
           parser.catalog[0], arguments(1).typeName) <> 0 Then
        Return LowerCBodyUnsignedCheckedOverflowCall( _
            parser, value, arguments(), operationKind, resultType, resultWidth)
    End If
    Dim minimumValue As String = _
        "CLongDoubleFromUnsignedValue(Cast(ULongInt, 0))"
    Dim maximumValue As String
    If overflowIsUnsigned <> 0 Then
        Select Case resultWidth
        Case 8: maximumValue = "CLongDoubleFromUnsignedValue(Cast(ULongInt, 255))"
        Case 16: maximumValue = "CLongDoubleFromUnsignedValue(Cast(ULongInt, 65535))"
        Case 32
            maximumValue = _
                "CLongDoubleFromUnsignedValue(Cast(ULongInt, 4294967295ULL))"
        Case 64
            maximumValue = _
                "CLongDoubleFromUnsignedValue(Cast(ULongInt, 18446744073709551615ULL))"
        Case Else: Return 0
        End Select
    Else
        Select Case resultWidth
        Case 8
            minimumValue = "CLongDoubleFromSignedValue(Cast(LongInt, -128))"
            maximumValue = "CLongDoubleFromSignedValue(Cast(LongInt, 127))"
        Case 16
            minimumValue = "CLongDoubleFromSignedValue(Cast(LongInt, -32768))"
            maximumValue = "CLongDoubleFromSignedValue(Cast(LongInt, 32767))"
        Case 32
            minimumValue = _
                "-CLongDoubleFromSignedValue(Cast(LongInt, 2147483647)) - " & _
                "CLongDoubleFromSignedValue(Cast(LongInt, 1))"
            maximumValue = _
                "CLongDoubleFromSignedValue(Cast(LongInt, 2147483647))"
        Case 64
            minimumValue = _
                "-CLongDoubleFromSignedValue(Cast(LongInt, 9223372036854775807LL)) - " & _
                "CLongDoubleFromSignedValue(Cast(LongInt, 1))"
            maximumValue = _
                "CLongDoubleFromSignedValue(Cast(LongInt, 9223372036854775807LL))"
        Case Else
            Return 0
        End Select
    End If

    Dim operationText As String = "+"
    Select Case operationKind
    Case 1: operationText = "+"
    Case 2: operationText = "-"
    Case 3: operationText = "*"
    Case Else: Return 0
    End Select

    Dim wideValue As String = NewSimpleTemporary(parser, "CLongDouble")
    Dim overflowFlag As String = NewSimpleTemporary(parser, "c2fb_c_int")
    Dim convertedValue As String = NewSimpleTemporary(parser, resultType)
    If wideValue = "" OrElse overflowFlag = "" OrElse convertedValue = "" Then Return 0

    ' Compare in extended precision; perform the stored result through unsigned
    ' bits so signed overflow is never evaluated by the BASIC backend.
    Dim wideLeft As String = SimpleValueCast( _
        parser.translation[0], parser.catalog[0], arguments(0), "CLongDouble")
    Dim wideRight As String = SimpleValueCast( _
        parser.translation[0], parser.catalog[0], arguments(1), "CLongDouble")
    If wideLeft = "" OrElse wideRight = "" Then Return 0
    value.prelude &= wideValue & " = (" & wideLeft & " " & operationText & _
                     " " & wideRight & ")" & Chr(10)
    value.prelude &= overflowFlag & " = 0" & Chr(10)
    value.prelude &= "If " & wideValue & " < (" & minimumValue & ") OrElse " & _
                     wideValue & " > (" & maximumValue & ") Then" & Chr(10) & _
                     "    " & overflowFlag & " = 1" & Chr(10) & "End If" & Chr(10)

    Dim leftBits As String = "Cast(ULongInt, " & arguments(0).text & ")"
    Dim rightBits As String = "Cast(ULongInt, " & arguments(1).text & ")"
    Dim resultBits As String = "(" & leftBits & " " & operationText & _
                               " " & rightBits & ")"
    Select Case resultWidth
    Case 8: resultBits = "(" & resultBits & " And 255ULL)"
    Case 16: resultBits = "(" & resultBits & " And 65535ULL)"
    Case 32: resultBits = "(" & resultBits & " And 4294967295ULL)"
    End Select
    value.prelude &= convertedValue & " = Cast(" & resultType & ", " & _
                     resultBits & ")" & Chr(10)
    value.prelude &= "CPtr(" & resultType & " Ptr, " & arguments(2).text & _
                     ")[0] = " & convertedValue & Chr(10)
    value.text = overflowFlag
    value.typeName = "c2fb_c_int"
    value.layoutType = value.typeName
    value.storageType = value.typeName
    value.cRecord = ""
    value.isLValue = 0
    value.isFunctionDesignator = 0
    value.lValueText = ""
    value.isWholeCall = 0
    value.arrayCount = 0
    value.arrayBound = ""
    value.arrayElementType = ""
    Return -1
End Function

Private Function LowerCBodyCheckedOverflowPredicateCall( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, arguments() As SimpleExpressionValue, _
    ByVal argumentCount As Long, ByVal operationKind As Long _
) As Long
    If argumentCount <> 3 OrElse parser.context = 0 Then Return 0
    ' GCC uses a bit-field's declared width here; scalar type widths do not
    ' preserve that range, so leave those cases to the unsupported subset.
    If arguments(2).bitWidth >= 0 OrElse _
       arguments(2).isDirectBitField <> 0 OrElse _
       arguments(2).isPackedBitField <> 0 Then Return 0
    Dim resultType As String = arguments(2).typeName
    If Left(resultType, 6) = "Const " Then resultType = Mid(resultType, 7)
    Dim resultWidth As Long = _
        SimpleIntegerWidthInBits(parser.catalog[0], resultType)
    If resultType = "" OrElse resultWidth = 0 OrElse _
       SimpleIntegerWidthInBits( _
           parser.catalog[0], arguments(0).typeName) = 0 OrElse _
       SimpleIntegerWidthInBits( _
           parser.catalog[0], arguments(1).typeName) = 0 Then Return 0

    If parser.unevaluated <> 0 Then
        value.text = "0"
        value.typeName = "c2fb_c_int"
        value.layoutType = value.typeName
        value.storageType = value.typeName
        value.isLValue = 0
        value.isFunctionDesignator = 0
        Return -1
    End If

    ' GCC uses the third argument's type for the result range. Its value is
    ' ignored, but side effects in that expression still run.
    For argumentIndex As Long = 0 To 2
        If FreezeSimpleValue(parser, arguments(argumentIndex)) = 0 Then Return 0
        value.prelude &= arguments(argumentIndex).prelude
    Next

    Dim overflowFlag As String = NewSimpleTemporary(parser, "c2fb_c_int")
    If overflowFlag = "" Then Return 0
    value.prelude &= overflowFlag & " = 0" & Chr(10)

    Dim overflowIsUnsigned As Long = CInt( _
        SimpleArithmeticTypeIsUnsigned(parser.catalog[0], resultType) <> 0)
    If overflowIsUnsigned <> 0 AndAlso _
       SimpleArithmeticTypeIsUnsigned( _
           parser.catalog[0], arguments(0).typeName) <> 0 AndAlso _
       SimpleArithmeticTypeIsUnsigned( _
           parser.catalog[0], arguments(1).typeName) <> 0 Then
        Dim maximumValue As String
        Select Case resultWidth
        Case 8: maximumValue = "255ULL"
        Case 16: maximumValue = "65535ULL"
        Case 32: maximumValue = "4294967295ULL"
        Case 64: maximumValue = "18446744073709551615ULL"
        Case Else: Return 0
        End Select
        Dim leftValue As String = NewSimpleTemporary(parser, "ULongInt")
        Dim rightValue As String = NewSimpleTemporary(parser, "ULongInt")
        If leftValue = "" OrElse rightValue = "" Then Return 0
        value.prelude &= leftValue & " = Cast(ULongInt, " & _
            arguments(0).text & ")" & Chr(10)
        value.prelude &= rightValue & " = Cast(ULongInt, " & _
            arguments(1).text & ")" & Chr(10)

        Select Case operationKind
        Case 1
            ' Compare before addition so the check itself cannot wrap.
            value.prelude &= "If " & rightValue & " > " & maximumValue & _
                " OrElse " & leftValue & " > (" & maximumValue & " - " & _
                rightValue & ") Then" & Chr(10) & _
                "    " & overflowFlag & " = 1" & Chr(10) & "End If" & Chr(10)
        Case 2
            value.prelude &= "If " & leftValue & " < " & rightValue & _
                " OrElse (" & leftValue & " - " & rightValue & ") > " & _
                maximumValue & " Then" & Chr(10) & _
                "    " & overflowFlag & " = 1" & Chr(10) & "End If" & Chr(10)
        Case 3
            value.prelude &= "If " & rightValue & " <> 0 AndAlso " & _
                leftValue & " > (" & maximumValue & " \ " & _
                rightValue & ") Then" & Chr(10) & _
                "    " & overflowFlag & " = 1" & Chr(10) & "End If" & Chr(10)
        Case Else
            Return 0
        End Select
    Else
        Dim minimumValue As String = _
            "CLongDoubleFromUnsignedValue(Cast(ULongInt, 0))"
        Dim maximumValue As String
        If overflowIsUnsigned <> 0 Then
            Select Case resultWidth
            Case 8
                maximumValue = "CLongDoubleFromUnsignedValue(Cast(ULongInt, 255))"
            Case 16
                maximumValue = "CLongDoubleFromUnsignedValue(Cast(ULongInt, 65535))"
            Case 32
                maximumValue = _
                    "CLongDoubleFromUnsignedValue(Cast(ULongInt, 4294967295ULL))"
            Case 64
                maximumValue = _
                    "CLongDoubleFromUnsignedValue(Cast(ULongInt, 18446744073709551615ULL))"
            Case Else: Return 0
            End Select
        Else
            Select Case resultWidth
            Case 8
                minimumValue = "CLongDoubleFromSignedValue(Cast(LongInt, -128))"
                maximumValue = "CLongDoubleFromSignedValue(Cast(LongInt, 127))"
            Case 16
                minimumValue = "CLongDoubleFromSignedValue(Cast(LongInt, -32768))"
                maximumValue = "CLongDoubleFromSignedValue(Cast(LongInt, 32767))"
            Case 32
                minimumValue = _
                    "-CLongDoubleFromSignedValue(Cast(LongInt, 2147483647)) - " & _
                    "CLongDoubleFromSignedValue(Cast(LongInt, 1))"
                maximumValue = _
                    "CLongDoubleFromSignedValue(Cast(LongInt, 2147483647))"
            Case 64
                minimumValue = _
                    "-CLongDoubleFromSignedValue(Cast(LongInt, 9223372036854775807LL)) - " & _
                    "CLongDoubleFromSignedValue(Cast(LongInt, 1))"
                maximumValue = _
                    "CLongDoubleFromSignedValue(Cast(LongInt, 9223372036854775807LL))"
            Case Else: Return 0
            End Select
        End If

        Dim operationText As String
        Select Case operationKind
        Case 1: operationText = "+"
        Case 2: operationText = "-"
        Case 3: operationText = "*"
        Case Else: Return 0
        End Select
        Dim wideValue As String = NewSimpleTemporary(parser, "CLongDouble")
        Dim wideLeft As String = SimpleValueCast( _
            parser.translation[0], parser.catalog[0], arguments(0), "CLongDouble")
        Dim wideRight As String = SimpleValueCast( _
            parser.translation[0], parser.catalog[0], arguments(1), "CLongDouble")
        If wideValue = "" OrElse wideLeft = "" OrElse wideRight = "" Then Return 0
        value.prelude &= wideValue & " = (" & wideLeft & " " & _
            operationText & " " & wideRight & ")" & Chr(10)
        value.prelude &= "If " & wideValue & " < (" & minimumValue & _
            ") OrElse " & wideValue & " > (" & maximumValue & ") Then" & _
            Chr(10) & "    " & overflowFlag & " = 1" & Chr(10) & _
            "End If" & Chr(10)
    End If

    value.text = overflowFlag
    value.typeName = "c2fb_c_int"
    value.layoutType = value.typeName
    value.storageType = value.typeName
    value.cRecord = ""
    value.isLValue = 0
    value.isFunctionDesignator = 0
    value.lValueText = ""
    value.isWholeCall = 0
    value.arrayCount = 0
    value.arrayBound = ""
    value.arrayElementType = ""
    Return -1
End Function

Private Function CBodyDefaultArgumentPromotionType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceType As String, ByRef targetType As String _
) As Long
    targetType = ""
    If InStr(sourceType, " Ptr") <> 0 OrElse _
       IsCBodyCallbackTypeInContext(translation, sourceType) <> 0 Then _
        Return -1

    Dim arithmeticKind As Long = SimpleArithmeticKind(catalog, sourceType)
    Select Case arithmeticKind
    Case 1, 2
        Dim sourceWidth As Long = _
            SimpleIntegerWidthInBits(catalog, sourceType)
        Dim intSize As Long = GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_INT__")
        If sourceWidth <= 0 Then Return 0
        If intSize <= 0 Then intSize = 4
        Dim intWidth As Long = intSize * 8
        If sourceWidth < intWidth Then
            targetType = "c2fb_c_int"
        ElseIf sourceWidth = intWidth AndAlso _
               SimpleArithmeticTypeIsUnsigned(catalog, sourceType) <> 0 Then
            targetType = "c2fb_c_uint"
        End If
        Return -1
    Case 3, 4, 6, 7, 8, 9
        ' Wider integers and double-width floating values need no promotion.
        Return -1
    Case 5
        targetType = "Double"
        Return -1
    End Select
    Return 0
End Function

Private Function ParseSimpleCallValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue, _
    ByVal procedureName As String, ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    Dim isVaStart As Long = CInt( _
        procedureName = "__builtin_va_start" OrElse _
        procedureName = "__builtin_c23_va_start")
    Dim isVaEnd As Long = CInt(procedureName = "__builtin_va_end")
    Dim isVaCopy As Long = CInt(procedureName = "__builtin_va_copy")
    Dim isAlloca As Long = CInt(procedureName = "__builtin_alloca")
    Dim isAtomicLoad As Long = CInt(procedureName = "__atomic_load_n")
    Dim isAtomicStore As Long = CInt(procedureName = "__atomic_store_n")
    Dim isAtomicExchange As Long = CInt(procedureName = "__atomic_exchange_n")
    Dim isAtomicFetchAdd As Long = CInt(procedureName = "__atomic_fetch_add")
    Dim isAtomicFetchSub As Long = CInt(procedureName = "__atomic_fetch_sub")
    Dim isAtomicFetchOr As Long = CInt(procedureName = "__atomic_fetch_or")
    Dim isAtomicFetchAnd As Long = CInt(procedureName = "__atomic_fetch_and")
    Dim isAtomicFetchXor As Long = CInt(procedureName = "__atomic_fetch_xor")
    Dim isAtomicCompareExchange As Long = _
        CInt(procedureName = "__atomic_compare_exchange_n")
    Dim isAtomicTestAndSet As Long = CInt(procedureName = "__atomic_test_and_set")
    Dim isAtomicClear As Long = CInt(procedureName = "__atomic_clear")
    Dim isAtomicThreadFence As Long = _
        CInt(procedureName = "__atomic_thread_fence")
    Dim isAtomicIsLockFree As Long = _
        CInt(procedureName = "__atomic_is_lock_free")
    Dim checkedOverflowKind As Long = _
        CBodyBuiltinCheckedOverflowKind(procedureName)
    Dim checkedOverflowPredicateKind As Long = _
        CBodyBuiltinCheckedOverflowPredicateKind(procedureName)
    Dim isFiniteBuiltin As Long = CBodyFiniteTestBuiltin(procedureName)
    Dim isNaNBuiltin As Long = CBodyNaNTestBuiltin(procedureName)
    Dim isInfinitySignBuiltin As Long = _
        CBodyInfinitySignTestBuiltin(procedureName)
    Dim builtinExpectKind As Long = CBodyBuiltinExpectKind(procedureName)
    Dim builtinConstantPKind As Long = CBodyBuiltinConstantP(procedureName)
    Dim builtinStdBitCountKind As Long = _
        CBodyBuiltinStdBitCountKind(procedureName)
    Dim builtinStdRotateKind As Long = _
        CBodyBuiltinStdRotateKind(procedureName)
    Dim builtinInfinityType As String = _
        CBodyBuiltinInfinityType(procedureName)
    Dim builtinNaNType As String = CBodyBuiltinNaNType(procedureName)
    Dim isCpuSupportsBuiltin As Long = _
        CBodyBuiltinCpuSupports(procedureName)
    Dim callbackType As String = value.typeName
    Dim isDirectProcedureCall As Long = 0
    Dim isParameterCall As Long = 0
    For parameterIndex As Long = 0 To parameterCount - 1
        If procedureName = parameterNames(parameterIndex) OrElse _
           procedureName = parameterAliases(parameterIndex) Then
            isParameterCall = -1
            Exit For
        End If
    Next
    If isParameterCall = 0 AndAlso procedureName <> "" AndAlso _
       value.isLValue = 0 AndAlso _
       value.isFunctionDesignator = 0 AndAlso _
       (CBodyProcedureIndex( _
            parser.translation[0], procedureName) >= 0 OrElse _
        C2fbNameListContains( _
            callableNames(), callableCount, procedureName) <> 0) Then _
        isDirectProcedureCall = -1
    Dim callbackIndex As Long = -1
    If isDirectProcedureCall = 0 Then _
        callbackIndex = CBodyCallbackIndexInContext( _
            parser.translation[0], callbackType)
    Dim isVariadicCall As Long = 0
    Dim variadicFixedParameterCount As Long = 0
    If callbackIndex >= 0 Then
        With parser.translation[0].body.callbacks(callbackIndex)
            If .isVariadic <> 0 Then
                isVariadicCall = -1
                variadicFixedParameterCount = .parameterCount
            End If
        End With
    ElseIf isDirectProcedureCall <> 0 Then
        Dim variadicProcedureIndex As Long = _
            CBodyProcedureIndex(parser.translation[0], procedureName)
        If variadicProcedureIndex >= 0 Then
            With parser.translation[0].symbolTable.symbols( _
                variadicProcedureIndex).body
                If .isVariadic <> 0 Then
                    isVariadicCall = -1
                    variadicFixedParameterCount = .parameterCount
                End If
            End With
        Else
            variadicProcedureIndex = FbBodyCallSignatureIndex( _
                parser.catalog[0], procedureName)
            If variadicProcedureIndex >= 0 Then
                With parser.catalog[0].bodyCallSignatures( _
                    variadicProcedureIndex)
                    If .isVariadic <> 0 Then
                        isVariadicCall = -1
                        variadicFixedParameterCount = .parameterCount
                    End If
                End With
            End If
        End If
    End If
    If isVariadicCall <> 0 AndAlso variadicFixedParameterCount < 1 Then _
        Return 0
    Dim expectedCount As Long = -1
    Dim returnType As String = value.typeName
    If builtinInfinityType <> "" Then
        expectedCount = 0
        returnType = builtinInfinityType
    ElseIf checkedOverflowKind <> 0 OrElse _
           checkedOverflowPredicateKind <> 0 Then
        expectedCount = 3
        returnType = "c2fb_c_int"
    ElseIf builtinExpectKind <> 0 Then
        expectedCount = 2
        If builtinExpectKind = 2 Then expectedCount = 3
        returnType = "c2fb_c_long"
    ElseIf builtinConstantPKind <> 0 Then
        expectedCount = 1
        returnType = "c2fb_c_int"
    ElseIf isCpuSupportsBuiltin <> 0 Then
        expectedCount = 1
        returnType = "c2fb_c_int"
    ElseIf CBodyBuiltinType(procedureName) <> "" Then
        expectedCount = 1
        returnType = CBodyBuiltinType(procedureName)
    ElseIf builtinStdRotateKind <> 0 Then
        expectedCount = 2
        returnType = "c2fb_c_uint"
    ElseIf builtinStdBitCountKind <> 0 Then
        expectedCount = 1
        returnType = IIf( _
            builtinStdBitCountKind = 3, "c2fb_c_int", "c2fb_c_uint")
    End If
    If isFiniteBuiltin <> 0 OrElse isNaNBuiltin <> 0 OrElse _
       isInfinitySignBuiltin <> 0 Then
        expectedCount = 1
        returnType = "c2fb_c_int"
    ElseIf builtinNaNType <> "" Then
        expectedCount = 1
        returnType = builtinNaNType
    ElseIf isVaStart <> 0 Then
        expectedCount = 2
        returnType = "void"
    ElseIf isVaEnd <> 0 Then
        expectedCount = 1
        returnType = "void"
    ElseIf isVaCopy <> 0 Then
        expectedCount = 2
        returnType = "void"
    ElseIf isAlloca <> 0 Then
        expectedCount = 1
        returnType = "Any Ptr"
    ElseIf isAtomicLoad <> 0 Then
        If parser.translation[0].body.assumeSingleThreadedAtomics = 0 AndAlso _
           parser.translation[0].body.atomicMutexRuntime = 0 Then Return 0
        expectedCount = 2
    ElseIf isAtomicStore <> 0 Then
        If parser.translation[0].body.assumeSingleThreadedAtomics = 0 AndAlso _
           parser.translation[0].body.atomicMutexRuntime = 0 Then Return 0
        expectedCount = 3
        returnType = "void"
    ElseIf isAtomicExchange <> 0 OrElse isAtomicFetchAdd <> 0 OrElse _
           isAtomicFetchSub <> 0 OrElse isAtomicFetchOr <> 0 OrElse _
           isAtomicFetchAnd <> 0 OrElse isAtomicFetchXor <> 0 OrElse _
           isAtomicCompareExchange <> 0 OrElse isAtomicThreadFence <> 0 OrElse _
           isAtomicIsLockFree <> 0 OrElse isAtomicTestAndSet <> 0 OrElse _
           isAtomicClear <> 0 Then
        If parser.translation[0].body.atomicMutexRuntime = 0 Then Return 0
        If isAtomicThreadFence <> 0 Then
            expectedCount = 1
            returnType = "void"
        ElseIf isAtomicIsLockFree <> 0 Then
            expectedCount = 2
            returnType = "c2fb_c_int"
        ElseIf isAtomicTestAndSet <> 0 OrElse isAtomicClear <> 0 Then
            expectedCount = 2
            If isAtomicClear <> 0 Then returnType = "void"
            If isAtomicTestAndSet <> 0 Then returnType = "c2fb_c_int"
        Else
            expectedCount = 3
        End If
        If isAtomicCompareExchange <> 0 Then
            expectedCount = 6
            returnType = "c2fb_c_int"
        End If
    End If
    If IsCBodyCallbackTypeInContext(parser.translation[0], callbackType) <> 0 Then
        If callbackIndex >= 0 Then
            expectedCount = _
                parser.translation[0].body.callbacks(callbackIndex).parameterCount
            returnType = _
                parser.translation[0].body.callbacks(callbackIndex).returnType
        ElseIf isDirectProcedureCall = 0 Then
            Return 0
        End If
    End If
    If isVariadicCall <> 0 Then _
        expectedCount = variadicFixedParameterCount
    parser.hasFunctionCall = -1
    parser.position += 1
    Dim arguments() As SimpleExpressionValue
    Dim targetTypes() As String
    Dim argumentSourceTexts() As String
    ReDim arguments(0 To 7)
    ReDim targetTypes(0 To 7)
    ReDim argumentSourceTexts(0 To 7)
    Dim argumentCount As Long = 0
    Dim hasPrelude As Long = (value.prelude <> "")
    SkipCSpaces(parser.sourceText, parser.position)
    If Mid(parser.sourceText, parser.position, 1) <> ")" Then
        Do
            If argumentCount >= MAX_SIMPLE_VARIABLES Then Return 0
            If argumentCount > UBound(arguments) Then
                ReDim Preserve arguments(0 To UBound(arguments) * 2 + 1)
                ReDim Preserve targetTypes(0 To UBound(targetTypes) * 2 + 1)
                ReDim Preserve argumentSourceTexts( _
                    0 To UBound(argumentSourceTexts) * 2 + 1)
            End If
            Dim argumentSourceStart As Long = parser.position
            Dim targetType As String
            If callbackIndex >= 0 Then
                targetType = CBodyCallbackParameterTypeInContext( _
                    parser.translation[0], callbackType, argumentCount)
            Else
                targetType = CBodyCallParameterType( _
                    parser.translation[0], parser.catalog[0], _
                    procedureName, argumentCount)
            End If
            ' An address-of-array expression passed to void * has the same
            ' address as its first element; lower it with the parameter type.
            Dim isExtraVariadicArgument As Long = CInt( _
                isVariadicCall <> 0 AndAlso _
                argumentCount >= variadicFixedParameterCount) * -1
            Dim previousTargetType As String = parser.targetType
            If isExtraVariadicArgument <> 0 Then
                parser.targetType = ""
            ElseIf targetType <> "" Then
                parser.targetType = targetType
            End If
            ' C call separators are not comma operators. A parenthesized comma
            ' expression still enters the full expression parser from unary.
            Dim argumentParseStatus As Long = ParseSimpleExpressionValue( _
                parser, arguments(argumentCount), 2, depth + 1, _
                callableNames(), callableCount, parameterNames(), _
                parameterAliases(), parameterTypes(), parameterCount)
            parser.targetType = previousTargetType
            If argumentParseStatus = 0 Then Return 0
            If isExtraVariadicArgument <> 0 Then
                Dim promotedType As String
                If CBodyDefaultArgumentPromotionType( _
                    parser.translation[0], parser.catalog[0], _
                    arguments(argumentCount).typeName, promotedType) = 0 Then _
                    Return 0
                targetType = promotedType
            End If
            argumentSourceTexts(argumentCount) = Trim(Mid( _
                parser.sourceText, argumentSourceStart, _
                parser.position - argumentSourceStart))
            targetTypes(argumentCount) = targetType
            If arguments(argumentCount).isArrayStorageAlias <> 0 Then
                If targetType = "" OrElse InStr(targetType, " Ptr") = 0 Then _
                    Return 0
                arguments(argumentCount).text = _
                    "CPtr(" & targetType & ", @(" & _
                    arguments(argumentCount).text & "))"
                arguments(argumentCount).typeName = targetType
                arguments(argumentCount).layoutType = targetType
                arguments(argumentCount).storageType = targetType
                arguments(argumentCount).arrayBound = ""
                arguments(argumentCount).arrayElementType = ""
                arguments(argumentCount).isArrayStorageAlias = 0
            End If
            Dim pointerArrayFormalIndex As Long = _
                CBodyPointerToArrayParameterIndexByPositionInContext( _
                    parser.translation[0], procedureName, argumentCount)
            If arguments(argumentCount).isPointerToArray <> 0 Then
                If pointerArrayFormalIndex >= 0 Then
                    If parser.translation[0].body.pointerToArrayParameters( _
                        pointerArrayFormalIndex).arrayElementCount <> _
                       arguments(argumentCount).pointerToArrayElementCount Then _
                        Return 0
                ElseIf targetType <> "Any Ptr" AndAlso _
                       targetType <> "Const Any Ptr" Then
                    Return 0
                End If
            End If
            If (InStr(arguments(argumentCount).typeName, " Ptr") <> 0 OrElse IsCBodyCallbackTypeInContext(parser.translation[0], arguments(argumentCount).typeName) <> 0) AndAlso _
               SimpleArithmeticKind(parser.catalog[0], targetType) > 0 Then Return 0
            If arguments(argumentCount).typeName = "void" Then Return 0
            If arguments(argumentCount).prelude <> "" Then hasPrelude = -1
            argumentCount += 1
            SkipCSpaces(parser.sourceText, parser.position)
            If Mid(parser.sourceText, parser.position, 1) <> "," Then Exit Do
            parser.position += 1
        Loop
    End If
    If expectedCount >= 0 Then
        If isVariadicCall <> 0 Then
            If argumentCount < expectedCount Then Return 0
        ElseIf argumentCount <> expectedCount Then
            Return 0
        End If
    End If
    Dim explainAdapter As String
    If procedureName = "sqlite3VdbeExplain" Then
        Select Case argumentCount
        Case 3
            explainAdapter = "sqlite3VdbeExplainText"
        Case 4
            Dim argumentKind As Long = SimpleArithmeticKind(parser.catalog[0], arguments(3).typeName)
            If argumentKind > 0 AndAlso argumentKind <= 4 Then
                explainAdapter = "sqlite3VdbeExplainInteger"
                targetTypes(3) = "c2fb_c_int"
            ElseIf InStr(arguments(3).typeName, " Ptr") <> 0 Then
                explainAdapter = "sqlite3VdbeExplainString"
                targetTypes(3) = "Const ZString Ptr"
            End If
        Case 5
            If SimpleArithmeticKind( _
                parser.catalog[0], arguments(3).typeName) > 0 AndAlso _
               SimpleArithmeticKind( _
                parser.catalog[0], arguments(3).typeName) <= 4 AndAlso _
               InStr(arguments(4).typeName, " Ptr") <> 0 Then
                explainAdapter = "sqlite3VdbeExplainIntegerString"
                targetTypes(3) = "c2fb_c_int"
                targetTypes(4) = "Const ZString Ptr"
            ElseIf InStr(arguments(3).typeName, " Ptr") <> 0 AndAlso _
               SimpleArithmeticKind(parser.catalog[0], arguments(4).typeName) > 0 AndAlso _
               SimpleArithmeticKind(parser.catalog[0], arguments(4).typeName) <= 4 Then
                explainAdapter = "sqlite3VdbeExplainStringInteger"
                targetTypes(3) = "Const ZString Ptr"
                targetTypes(4) = "c2fb_c_int"
            ElseIf InStr(arguments(3).typeName, " Ptr") <> 0 AndAlso _
                   InStr(arguments(4).typeName, " Ptr") <> 0 Then
                explainAdapter = "sqlite3VdbeExplainStrings2"
                targetTypes(3) = "Const ZString Ptr"
                targetTypes(4) = "Const ZString Ptr"
            End If
        Case 6
            If InStr(arguments(3).typeName, " Ptr") <> 0 AndAlso _
               InStr(arguments(4).typeName, " Ptr") <> 0 AndAlso _
               InStr(arguments(5).typeName, " Ptr") <> 0 Then
                explainAdapter = "sqlite3VdbeExplainStrings3"
                targetTypes(3) = "Const ZString Ptr"
                targetTypes(4) = "Const ZString Ptr"
                targetTypes(5) = "Const ZString Ptr"
            End If
        End Select
        If explainAdapter = "" Then Return 0
    End If
    If builtinExpectKind <> 0 Then
        If parser.unevaluated = 0 AndAlso argumentCount <> expectedCount Then Return 0
        For argumentIndex As Long = 0 To argumentCount - 1
            Dim argumentKind As Long = SimpleArithmeticKind( _
                parser.catalog[0], arguments(argumentIndex).typeName)
            If argumentKind < 1 OrElse argumentKind > 6 Then Return 0
        Next
        targetTypes(0) = "c2fb_c_long"
        targetTypes(1) = "c2fb_c_long"
        If builtinExpectKind = 1 Then
            explainAdapter = "__c2fb_builtin_expect"
        Else
            targetTypes(2) = "Double"
            explainAdapter = "__c2fb_builtin_expect_with_probability"
        End If
    End If
    If Mid(parser.sourceText, parser.position, 1) <> ")" Then Return 0
    parser.position += 1
    If isCpuSupportsBuiltin <> 0 Then _
        Return LowerCBodyBuiltinCpuSupportsCall( _
            parser, value, arguments(), argumentSourceTexts(), argumentCount)
    If checkedOverflowPredicateKind <> 0 Then _
        Return LowerCBodyCheckedOverflowPredicateCall( _
            parser, value, arguments(), argumentCount, _
            checkedOverflowPredicateKind)
    If checkedOverflowKind <> 0 Then _
        Return LowerCBodyCheckedOverflowCall( _
            parser, value, arguments(), argumentCount, checkedOverflowKind)
    If builtinStdRotateKind <> 0 Then _
        Return LowerCBodyStdRotateCall( _
            parser, value, arguments(), argumentCount, builtinStdRotateKind)
    If builtinStdBitCountKind <> 0 Then _
        Return LowerCBodyStdBitCountCall( _
            parser, value, arguments(), argumentCount, builtinStdBitCountKind)
    If builtinConstantPKind <> 0 Then _
        Return LowerCBodyBuiltinConstantPCall( _
            parser, value, arguments(), argumentSourceTexts(), argumentCount, _
            callableNames(), callableCount, parameterNames(), _
            parameterAliases(), parameterCount)
    If builtinInfinityType <> "" Then
        If argumentCount <> 0 Then Return 0
        value.text = CBodyBuiltinInfinityExpression(procedureName)
        If value.text = "" Then Return 0
        value.typeName = builtinInfinityType
        value.layoutType = builtinInfinityType
        value.storageType = builtinInfinityType
        value.cRecord = ""
        value.isLValue = 0
        value.isAddressAccessor = 0
        value.lValueText = ""
        value.isWholeCall = 0
        value.isFunctionDesignator = 0
        value.arrayCount = 0
        value.arrayBound = ""
        value.arrayElementType = ""
        Return -1
    End If
    If builtinNaNType <> "" Then
        If argumentCount <> 1 Then Return 0
        ' Preserve payload semantics by translating only GCC's empty payload.
        If Trim(argumentSourceTexts(0)) <> (Chr(34) & Chr(34)) Then Return 0
        value.prelude &= arguments(0).prelude
        Select Case builtinNaNType
        Case "Single"
            value.text = "NAN_"
        Case "Double"
            value.text = "Cast(Double, NAN_)"
        Case "CLongDouble"
            value.text = _
                "CLongDoubleFromDoubleValue(Cast(Double, NAN_))"
        Case Else
            Return 0
        End Select
        value.typeName = builtinNaNType
        value.layoutType = builtinNaNType
        value.storageType = builtinNaNType
        value.cRecord = ""
        value.isLValue = 0
        value.isAddressAccessor = 0
        value.isReadOnly = 0
        value.lValueText = ""
        value.isWholeCall = 0
        value.isFunctionDesignator = 0
        value.arrayCount = 0
        value.arrayBound = ""
        value.arrayElementType = ""
        Return -1
    End If
    If isFiniteBuiltin <> 0 OrElse isNaNBuiltin <> 0 OrElse _
       isInfinitySignBuiltin <> 0 Then
        If argumentCount <> 1 Then Return 0
        Dim argumentKind As Long = _
            SimpleArithmeticKind(parser.catalog[0], arguments(0).typeName)
        Dim argumentIsInteger As Long = _
            SimpleArithmeticKindIsInteger(argumentKind)
        Dim argumentIsFloating As Long = _
            SimpleArithmeticKindIsFloating(argumentKind)
        If argumentKind <= 0 OrElse _
           (isFiniteBuiltin <> 0 AndAlso argumentKind > 6 AndAlso _
            argumentIsInteger = 0) OrElse _
           (isNaNBuiltin <> 0 AndAlso argumentIsInteger = 0 AndAlso _
            argumentIsFloating = 0) OrElse _
           (isInfinitySignBuiltin <> 0 AndAlso _
            argumentIsInteger = 0 AndAlso argumentIsFloating = 0) OrElse _
           FreezeSimpleValue(parser, arguments(0)) = 0 Then Return 0
        value.prelude &= arguments(0).prelude
        If parser.unevaluated <> 0 Then
            value.text = IIf( _
                isNaNBuiltin <> 0 OrElse isInfinitySignBuiltin <> 0, "0", "1")
        ElseIf argumentIsInteger <> 0 Then
            value.text = IIf( _
                isNaNBuiltin <> 0 OrElse isInfinitySignBuiltin <> 0, "0", "1")
        ElseIf isNaNBuiltin <> 0 Then
            ' C's isnan test is true exactly when the floating value is
            ' unordered with itself. Freeze the operand above so it is
            ' evaluated once even though the comparison names it twice.
            value.text = SimpleBooleanValue( _
                arguments(0).text & " <> " & arguments(0).text)
        ElseIf isInfinitySignBuiltin <> 0 Then
            ' Keep the signed result required by GCC's isinf builtin.
            Dim infinityValue As String = _
                CBodyBuiltinInfinityExpression("__builtin_inf")
            If infinityValue = "" Then Return 0
            value.text = "Cast(c2fb_c_int, IIf(" & arguments(0).text & _
                " = " & infinityValue & ", 1, IIf(" & _
                arguments(0).text & " = -" & infinityValue & ", -1, 0)))"
        Else
            value.text = "Cast(c2fb_c_int, IIf(Abs(CDbl(" & _
                arguments(0).text & ")) <= 1.7976931348623157e+308, 1, 0))"
        End If
        value.typeName = "c2fb_c_int"
        value.layoutType = value.typeName
        value.storageType = value.typeName
        value.cRecord = ""
        value.isLValue = 0
        value.isAddressAccessor = 0
        value.lValueText = ""
        value.isWholeCall = 0
        value.isFunctionDesignator = 0
        value.arrayCount = 0
        value.arrayBound = ""
        value.arrayElementType = ""
        Return -1
    End If
    If parser.translation[0].body.atomicMutexRuntime <> 0 AndAlso _
       (isAtomicLoad <> 0 OrElse isAtomicStore <> 0 OrElse _
        isAtomicExchange <> 0 OrElse isAtomicFetchAdd <> 0 OrElse _
        isAtomicFetchSub <> 0 OrElse isAtomicFetchOr <> 0 OrElse _
        isAtomicFetchAnd <> 0 OrElse isAtomicFetchXor <> 0 OrElse _
        isAtomicCompareExchange <> 0 OrElse isAtomicThreadFence <> 0 OrElse _
        isAtomicIsLockFree <> 0 OrElse isAtomicTestAndSet <> 0 OrElse _
        isAtomicClear <> 0) Then
        If parser.unevaluated <> 0 Then Return 0
        Dim pointeeType As String = SimplePointeeType(arguments(0).typeName)
        If Left(pointeeType, 6) = "Const " Then pointeeType = Mid(pointeeType, 7)
        Dim pointeeKind As Long = _
            SimpleArithmeticKind(parser.catalog[0], pointeeType)
        Dim pointeeIsPointer As Long = CInt( _
            Right(pointeeType, 4) = " Ptr" OrElse _
            IsCBodyCallbackTypeInContext( _
                parser.translation[0], pointeeType) <> 0) * -1
        Dim atomicPointer As String = arguments(0).text
        Dim atomicStorage As String = "CPtr(" & pointeeType & " Ptr, " & _
            atomicPointer & ")[0]"
        If isAtomicThreadFence <> 0 Then
            If FreezeSimpleValue(parser, arguments(0)) = 0 Then Return 0
            value.prelude &= arguments(0).prelude
            value.text = "FBC.fbLock()" & Chr(10) & "FBC.fbUnlock()"
            value.typeName = "void"
            value.layoutType = "void"
            value.storageType = "void"
            value.cRecord = ""
            value.isLValue = 0
            value.isAddressAccessor = 0
            value.lValueText = ""
            value.isWholeCall = -1
            value.isFunctionDesignator = 0
            value.arrayCount = 0
            value.arrayBound = ""
            value.arrayElementType = ""
            Return -1
        ElseIf isAtomicIsLockFree <> 0 Then
            For argumentIndex As Long = 0 To argumentCount - 1
                If FreezeSimpleValue(parser, arguments(argumentIndex)) = 0 Then Return 0
                value.prelude &= arguments(argumentIndex).prelude
            Next
            value.text = "0"
            value.typeName = "c2fb_c_int"
            value.layoutType = value.typeName
            value.storageType = value.typeName
            value.cRecord = ""
            value.isLValue = 0
            value.isAddressAccessor = 0
            value.lValueText = ""
            value.isWholeCall = 0
            value.isFunctionDesignator = 0
            value.arrayCount = 0
            value.arrayBound = ""
            value.arrayElementType = ""
            Return -1
        ElseIf isAtomicTestAndSet <> 0 Then
            If pointeeKind < 1 OrElse pointeeKind > 4 Then Return 0
            Dim previousFlag As String = NewSimpleTemporary(parser, pointeeType)
            Dim flagResult As String = NewSimpleTemporary(parser, "c2fb_c_int")
            If previousFlag = "" OrElse flagResult = "" Then Return 0
            value.prelude &= "FBC.fbLock()" & Chr(10) & _
                previousFlag & " = " & atomicStorage & Chr(10) & _
                atomicStorage & " = Cast(" & pointeeType & ", 1)" & Chr(10) & _
                flagResult & " = IIf(" & previousFlag & " <> 0, 1, 0)" & Chr(10) & _
                "FBC.fbUnlock()" & Chr(10)
            value.text = flagResult
            value.typeName = "c2fb_c_int"
            value.layoutType = value.typeName
            value.storageType = value.typeName
            value.cRecord = ""
            value.isLValue = 0
            value.isAddressAccessor = 0
            value.lValueText = ""
            value.isWholeCall = 0
            value.isFunctionDesignator = 0
            value.arrayCount = 0
            value.arrayBound = ""
            value.arrayElementType = ""
            Return -1
        ElseIf isAtomicClear <> 0 Then
            If pointeeKind < 1 OrElse pointeeKind > 4 Then Return 0
            value.prelude &= "FBC.fbLock()" & Chr(10)
            value.text = atomicStorage & " = Cast(" & pointeeType & ", 0)" & Chr(10) & _
                         "FBC.fbUnlock()"
            value.typeName = "void"
            value.layoutType = "void"
            value.storageType = "void"
            value.cRecord = ""
            value.isLValue = 0
            value.isAddressAccessor = 0
            value.lValueText = ""
            value.isWholeCall = -1
            value.isFunctionDesignator = 0
            value.arrayCount = 0
            value.arrayBound = ""
            value.arrayElementType = ""
            Return -1
        End If
        If pointeeType = "" OrElse _
           (pointeeKind < 1 OrElse pointeeKind > 4) AndAlso _
           pointeeIsPointer = 0 Then Return 0

        For argumentIndex As Long = 0 To argumentCount - 1
            If FreezeSimpleValue(parser, arguments(argumentIndex)) = 0 Then Return 0
            value.prelude &= arguments(argumentIndex).prelude
        Next

        If isAtomicLoad <> 0 Then
            Dim loadedValue As String = NewSimpleTemporary(parser, pointeeType)
            If loadedValue = "" Then Return 0
            value.prelude &= "FBC.fbLock()" & Chr(10) & _
                loadedValue & " = " & atomicStorage & Chr(10) & _
                "FBC.fbUnlock()" & Chr(10)
            value.text = loadedValue
            value.typeName = pointeeType
            value.layoutType = pointeeType
            value.storageType = pointeeType
            value.cRecord = ""
            value.isLValue = 0
            value.isAddressAccessor = 0
            value.lValueText = ""
            value.isWholeCall = 0
            value.isFunctionDesignator = 0
            value.arrayCount = 0
            value.arrayBound = ""
            value.arrayElementType = ""
            Return -1
        ElseIf isAtomicStore <> 0 Then
            Dim valueKind As Long = _
                SimpleArithmeticKind(parser.catalog[0], arguments(1).typeName)
            Dim valueIsPointer As Long = CInt( _
                Right(arguments(1).typeName, 4) = " Ptr" OrElse _
                IsCBodyCallbackTypeInContext( _
                    parser.translation[0], arguments(1).typeName) <> 0) * -1
            If (valueKind < 1 OrElse valueKind > 4) AndAlso _
               (pointeeIsPointer = 0 OrElse valueIsPointer = 0) Then Return 0
            Dim storedValue As String = SimpleValueCast( _
                parser.translation[0], parser.catalog[0], _
                arguments(1), pointeeType)
            If storedValue = "" Then Return 0
            value.prelude &= "FBC.fbLock()" & Chr(10)
            value.text = atomicStorage & " = " & storedValue & Chr(10) & _
                         "FBC.fbUnlock()"
            value.typeName = "void"
            value.layoutType = "void"
            value.storageType = "void"
            value.cRecord = ""
            value.isLValue = 0
            value.isAddressAccessor = 0
            value.lValueText = ""
            value.isWholeCall = -1
            value.isFunctionDesignator = 0
            value.arrayCount = 0
            value.arrayBound = ""
            value.arrayElementType = ""
            Return -1
        ElseIf isAtomicExchange <> 0 Then
            Dim valueKind As Long = _
                SimpleArithmeticKind(parser.catalog[0], arguments(1).typeName)
            Dim valueIsPointer As Long = CInt( _
                Right(arguments(1).typeName, 4) = " Ptr" OrElse _
                IsCBodyCallbackTypeInContext( _
                    parser.translation[0], arguments(1).typeName) <> 0) * -1
            If (valueKind < 1 OrElse valueKind > 4) AndAlso _
               (pointeeIsPointer = 0 OrElse valueIsPointer = 0) Then Return 0
            Dim exchangedValue As String = SimpleValueCast( _
                parser.translation[0], parser.catalog[0], _
                arguments(1), pointeeType)
            If exchangedValue = "" Then Return 0
            Dim previousValue As String = NewSimpleTemporary(parser, pointeeType)
            If previousValue = "" Then Return 0
            value.prelude &= "FBC.fbLock()" & Chr(10) & _
                previousValue & " = " & atomicStorage & Chr(10) & _
                atomicStorage & " = " & exchangedValue & Chr(10) & _
                "FBC.fbUnlock()" & Chr(10)
            value.text = previousValue
            value.typeName = pointeeType
            value.layoutType = pointeeType
            value.storageType = pointeeType
            value.cRecord = ""
            value.isLValue = 0
            value.isAddressAccessor = 0
            value.lValueText = ""
            value.isWholeCall = 0
            value.isFunctionDesignator = 0
            value.arrayCount = 0
            value.arrayBound = ""
            value.arrayElementType = ""
            Return -1
        ElseIf isAtomicFetchAdd <> 0 OrElse isAtomicFetchSub <> 0 OrElse _
               isAtomicFetchOr <> 0 OrElse isAtomicFetchAnd <> 0 OrElse _
               isAtomicFetchXor <> 0 Then
            If pointeeKind < 1 OrElse pointeeKind > 4 Then Return 0
            Dim valueKind As Long = _
                SimpleArithmeticKind(parser.catalog[0], arguments(1).typeName)
            If valueKind < 1 OrElse valueKind > 4 Then Return 0
            Dim addend As String = SimpleValueCast( _
                parser.translation[0], parser.catalog[0], _
                arguments(1), pointeeType)
            If addend = "" Then Return 0
            Dim previousValue As String = NewSimpleTemporary(parser, pointeeType)
            If previousValue = "" Then Return 0
            Dim updateOperator As String = "+"
            If isAtomicFetchSub <> 0 Then
                updateOperator = "-"
            ElseIf isAtomicFetchOr <> 0 Then
                updateOperator = "Or"
            ElseIf isAtomicFetchAnd <> 0 Then
                updateOperator = "And"
            ElseIf isAtomicFetchXor <> 0 Then
                updateOperator = "Xor"
            End If
            value.prelude &= "FBC.fbLock()" & Chr(10) & _
                previousValue & " = " & atomicStorage & Chr(10) & _
                atomicStorage & " = Cast(" & pointeeType & ", " & _
                previousValue & " " & updateOperator & " " & addend & ")" & Chr(10) & _
                "FBC.fbUnlock()" & Chr(10)
            value.text = previousValue
            value.typeName = pointeeType
            value.layoutType = pointeeType
            value.storageType = pointeeType
            value.cRecord = ""
            value.isLValue = 0
            value.isAddressAccessor = 0
            value.lValueText = ""
            value.isWholeCall = 0
            value.isFunctionDesignator = 0
            value.arrayCount = 0
            value.arrayBound = ""
            value.arrayElementType = ""
            Return -1
        ElseIf isAtomicCompareExchange <> 0 Then
            Dim expectedType As String = _
                SimplePointeeType(arguments(1).typeName)
            If Left(expectedType, 6) = "Const " Then expectedType = Mid(expectedType, 7)
            If expectedType <> pointeeType Then Return 0
            Dim desiredKind As Long = _
                SimpleArithmeticKind(parser.catalog[0], arguments(2).typeName)
            Dim desiredIsPointer As Long = CInt( _
                Right(arguments(2).typeName, 4) = " Ptr" OrElse _
                IsCBodyCallbackTypeInContext( _
                    parser.translation[0], arguments(2).typeName) <> 0) * -1
            If (desiredKind < 1 OrElse desiredKind > 4) AndAlso _
               (pointeeIsPointer = 0 OrElse desiredIsPointer = 0) Then Return 0
            Dim desiredValue As String = SimpleValueCast( _
                parser.translation[0], parser.catalog[0], _
                arguments(2), pointeeType)
            If desiredValue = "" Then Return 0
            Dim actualValue As String = NewSimpleTemporary(parser, pointeeType)
            Dim comparisonResult As String = _
                NewSimpleTemporary(parser, "c2fb_c_int")
            If actualValue = "" OrElse comparisonResult = "" Then Return 0
            Dim expectedStorage As String = "CPtr(" & pointeeType & " Ptr, " & _
                arguments(1).text & ")[0]"
            value.prelude &= "FBC.fbLock()" & Chr(10) & _
                actualValue & " = " & atomicStorage & Chr(10) & _
                "If " & actualValue & " = " & expectedStorage & " Then" & Chr(10) & _
                "    " & atomicStorage & " = " & desiredValue & Chr(10) & _
                "    " & comparisonResult & " = 1" & Chr(10) & _
                "Else" & Chr(10) & _
                "    " & expectedStorage & " = " & actualValue & Chr(10) & _
                "    " & comparisonResult & " = 0" & Chr(10) & _
                "End If" & Chr(10) & _
                "FBC.fbUnlock()" & Chr(10)
            value.text = comparisonResult
            value.typeName = "c2fb_c_int"
            value.layoutType = value.typeName
            value.storageType = value.typeName
            value.cRecord = ""
            value.isLValue = 0
            value.isAddressAccessor = 0
            value.lValueText = ""
            value.isWholeCall = 0
            value.isFunctionDesignator = 0
            value.arrayCount = 0
            value.arrayBound = ""
            value.arrayElementType = ""
            Return -1
        End If
    End If
    If isAtomicLoad <> 0 Then
        If parser.unevaluated <> 0 OrElse argumentCount <> 2 OrElse _
           arguments(1).prelude <> "" OrElse _
           SimpleIsNullValue(arguments(1)) = 0 Then _
            Return 0
        Dim pointeeType As String = SimplePointeeType(arguments(0).typeName)
        Dim pointeeKind As Long = _
            SimpleArithmeticKind(parser.catalog[0], pointeeType)
        ' C2FB lowers only relaxed integer loads. This path is enabled only
        ' when the caller promises that no other thread can access the object.
        If pointeeType = "" OrElse pointeeKind < 1 OrElse pointeeKind > 4 OrElse _
           FreezeSimpleValue(parser, arguments(0)) = 0 Then Return 0
        value.prelude &= arguments(0).prelude
        value.text = "CPtr(" & pointeeType & " Ptr, " & _
            arguments(0).text & ")[0]"
        value.typeName = pointeeType
        value.layoutType = pointeeType
        value.storageType = pointeeType
        value.cRecord = ""
        value.isLValue = 0
        value.isAddressAccessor = 0
        value.lValueText = ""
        value.isWholeCall = 0
        value.isFunctionDesignator = 0
        value.arrayCount = 0
        value.arrayBound = ""
        value.arrayElementType = ""
        Return -1
    ElseIf isAtomicStore <> 0 Then
        If parser.unevaluated <> 0 OrElse argumentCount <> 3 OrElse _
           arguments(2).prelude <> "" OrElse _
           SimpleIsNullValue(arguments(2)) = 0 Then _
            Return 0
        Dim pointeeType As String = SimplePointeeType(arguments(0).typeName)
        Dim pointeeKind As Long = _
            SimpleArithmeticKind(parser.catalog[0], pointeeType)
        Dim valueKind As Long = _
            SimpleArithmeticKind(parser.catalog[0], arguments(1).typeName)
        ' A typed scalar write preserves C's conversion at the target width.
        ' It is safe only when the caller promises no concurrent access.
        If pointeeType = "" OrElse pointeeKind < 1 OrElse pointeeKind > 4 OrElse _
           valueKind < 1 OrElse valueKind > 4 OrElse _
           FreezeSimpleValue(parser, arguments(0)) = 0 OrElse _
           FreezeSimpleValue(parser, arguments(1)) = 0 Then Return 0
        Dim storedValue As String = SimpleValueCast( _
            parser.translation[0], parser.catalog[0], arguments(1), pointeeType)
        If storedValue = "" Then Return 0
        value.prelude &= arguments(0).prelude
        value.prelude &= arguments(1).prelude
        value.text = "CPtr(" & pointeeType & " Ptr, " & _
            arguments(0).text & ")[0] = " & storedValue
        value.typeName = "void"
        value.layoutType = "void"
        value.storageType = "void"
        value.cRecord = ""
        value.isLValue = 0
        value.isAddressAccessor = 0
        value.lValueText = ""
        value.isWholeCall = -1
        value.isFunctionDesignator = 0
        value.arrayCount = 0
        value.arrayBound = ""
        value.arrayElementType = ""
        Return -1
    End If
    If isAlloca <> 0 Then
        If parser.unevaluated <> 0 OrElse argumentCount <> 1 OrElse _
           parser.context = 0 OrElse parser.context->allocaHeadName = "" OrElse _
           SimpleArithmeticKind( _
               parser.catalog[0], arguments(0).typeName) = 0 OrElse _
           FreezeSimpleValue(parser, arguments(0)) = 0 Then Return 0
        Dim allocationBase As String = NewSimpleTemporary(parser, "Any Ptr")
        Dim allocatedBuffer As String = NewSimpleTemporary(parser, "Any Ptr")
        If allocationBase = "" OrElse allocatedBuffer = "" Then Return 0
        Dim sizeExpression As String = _
            "Cast(UInteger, " & arguments(0).text & ")"
        Dim maximumSize As String = "Cast(ULongInt, Cast(UInteger, -1))"
        value.prelude &= arguments(0).prelude
        value.prelude &= "' Reserve two pointer slots for the link and aligned payload." & Chr(10)
        value.prelude &= "If Cast(ULongInt, " & sizeExpression & ") > " & _
            maximumSize & " - (2 * SizeOf(Any Ptr)) Then Error 7 ' FreeBASIC runtime error 7 reports allocation failure." & Chr(10)
        value.prelude &= allocationBase & " = Allocate(" & sizeExpression & _
            " + (2 * SizeOf(Any Ptr)))" & Chr(10)
        value.prelude &= "If " & allocationBase & " = 0 Then Error 7 ' FreeBASIC runtime error 7 reports allocation failure." & Chr(10)
        value.prelude &= "Cptr(Any Ptr Ptr, " & allocationBase & ")[0] = " & _
            parser.context->allocaHeadName & Chr(10)
        value.prelude &= parser.context->allocaHeadName & " = " & _
            allocationBase & Chr(10)
        value.prelude &= allocatedBuffer & " = Cptr(Any Ptr Ptr, " & _
            allocationBase & ") + 2" & Chr(10)
        value.text = allocatedBuffer
        value.typeName = returnType
        value.layoutType = returnType
        value.storageType = returnType
        value.cRecord = ""
        value.isLValue = 0
        value.isAddressAccessor = 0
        value.lValueText = ""
        value.isWholeCall = 0
        value.isFunctionDesignator = 0
        value.arrayCount = 0
        value.arrayBound = ""
        Return -1
    End If
    If CBodyBuiltinType(procedureName) <> "" Then
        If argumentCount <> 1 OrElse _
           FreezeSimpleValue(parser, arguments(0)) = 0 Then Return 0
        ' The byte-swap expression uses its input once per byte, so first
        ' materialize any C argument that has side effects.
        value.prelude &= arguments(0).prelude
        value.text = CBodyBuiltinByteSwapExpression( _
            procedureName, arguments(0).text)
        If value.text = "" Then Return 0
        value.typeName = returnType
        value.layoutType = returnType
        value.storageType = returnType
        value.cRecord = ""
        value.isLValue = 0
        value.isAddressAccessor = 0
        value.isWholeCall = 0
        value.isFunctionDesignator = 0
        value.arrayCount = 0
        value.arrayBound = ""
        Return -1
    End If
    ' ast-node-call.bas loads arguments in ABI order. When any argument needs
    ' statements, materialize all arguments in one allowed C evaluation order
    ' before the call. This retains sequence points within each argument.
    If hasPrelude <> 0 AndAlso callbackIndex >= 0 Then
        If FreezeSimpleValue(parser, value) = 0 Then Return 0
    End If
    If explainAdapter <> "" Then value.text = explainAdapter
    If isVaStart <> 0 Then value.text = "Cva_Start"
    If isVaCopy <> 0 Then value.text = "Cva_Copy"
    If isVaEnd <> 0 Then value.text = "Cva_End"
    value.text &= "("
    For i As Long = 0 To argumentCount - 1
        If hasPrelude <> 0 Then
            If FreezeSimpleValue(parser, arguments(i)) = 0 Then Return 0
            value.prelude &= arguments(i).prelude
        End If
        If i > 0 Then value.text &= ", "
        Dim argumentText As String = arguments(i).text
        If isVariadicCall <> 0 AndAlso _
           i >= variadicFixedParameterCount AndAlso targetTypes(i) <> "" Then
            argumentText = SimpleValueCast( _
                parser.translation[0], parser.catalog[0], _
                arguments(i), targetTypes(i))
            If argumentText = "" Then Return 0
        Else
            Dim halfFloatText As String = SimpleHalfFloatValueText( _
                parser.translation[0], parser.catalog[0], _
                arguments(i), targetTypes(i))
            If halfFloatText <> "" Then
                argumentText = halfFloatText
            ElseIf SimpleFloatingCastNeedsFix( _
                SimpleArithmeticKind( _
                    parser.catalog[0], arguments(i).typeName)) <> 0 AndAlso _
               SimpleArithmeticKindIsInteger( _
                   SimpleArithmeticKind(parser.catalog[0], targetTypes(i))) <> 0 Then
                argumentText = "Cast(" & targetTypes(i) & ", Fix(" & _
                    argumentText & "))"
            ElseIf targetTypes(i) <> "" AndAlso _
                   (SimpleArithmeticKind( _
                        parser.catalog[0], arguments(i).typeName) = 7 OrElse _
                    SimpleArithmeticKind( _
                        parser.catalog[0], targetTypes(i)) = 7) Then
                argumentText = SimpleValueCast( _
                    parser.translation[0], parser.catalog[0], _
                    arguments(i), targetTypes(i))
                If argumentText = "" Then Return 0
            ElseIf targetTypes(i) <> "" AndAlso _
                   (InStr(targetTypes(i), " Ptr") <> 0 OrElse _
                    IsCBodyCallbackTypeInContext( _
                        parser.translation[0], targetTypes(i)) <> 0) AndAlso _
                   SimpleIsNullValue(arguments(i)) <> 0 Then
                ' C converts an integer constant expression with value zero to
                ' the exact pointer type declared by the called function.
                argumentText = "CPtr(" & targetTypes(i) & ", 0)"
            ElseIf targetTypes(i) <> "" AndAlso _
                   targetTypes(i) <> arguments(i).typeName AndAlso _
                   (InStr(targetTypes(i), " Ptr") <> 0 OrElse _
                    IsCBodyCallbackTypeInContext( _
                        parser.translation[0], targetTypes(i)) <> 0) AndAlso _
                   (InStr(arguments(i).typeName, " Ptr") <> 0 OrElse _
                    IsCBodyCallbackTypeInContext( _
                        parser.translation[0], arguments(i).typeName) <> 0) Then
                ' C permits compatible object-pointer conversions at call sites.
                ' Preserve the FreeBASIC ABI declaration with an explicit cast
                ' when the port uses an opaque Any Ptr parameter.
                argumentText = SimpleValueCast( _
                    parser.translation[0], parser.catalog[0], _
                    arguments(i), targetTypes(i))
            End If
        End If
        value.text &= argumentText
    Next
    value.text &= ")"
    value.typeName = returnType
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.lValueText = ""
    value.layoutType = value.typeName
    value.storageType = value.typeName
    value.cRecord = CBodyRecordName(parser.translation[0], parser.catalog[0], value.typeName)
    value.isWholeCall = -1
    value.isFunctionDesignator = 0
    If InStr(returnType, " Ptr") <> 0 Then
        ' Port ABI declarations intentionally use Any Ptr for engine records.
        ' Retain the C result type before dereferencing or navigating members.
        value.text = "CPtr(" & returnType & ", " & value.text & ")"
        value.isWholeCall = 0
    End If
    Return -1
End Function

Private Function ParseSimpleVaArgValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If Mid(parser.sourceText, parser.position, 1) <> "(" Then Return 0
    parser.position += 1

    Dim vaListValue As SimpleExpressionValue
    If ParseSimpleExpressionValue(parser, vaListValue, 2, depth + 1, _
                                  callableNames(), callableCount, _
                                  parameterNames(), parameterAliases(), _
                                  parameterTypes(), parameterCount) = 0 Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If Mid(parser.sourceText, parser.position, 1) <> "," Then Return 0
    parser.position += 1
    SkipCSpaces(parser.sourceText, parser.position)

    Dim typeStart As Long = parser.position
    Dim typeEnd As Long = typeStart
    While typeEnd <= Len(parser.sourceText) AndAlso _
          Mid(parser.sourceText, typeEnd, 1) <> ")"
        typeEnd += 1
    Wend
    If typeEnd > Len(parser.sourceText) Then Return 0
    Dim sourceType As String = Trim(Mid(parser.sourceText, typeStart, typeEnd - typeStart))
    If sourceType = "" Then Return 0

    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(sourceType, typeTokens(), typeTokenCount)
    If typeTokenCount = 0 Then Return 0
    Dim resolvedArgumentType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel(parser.translation[0], parser.catalog[0], _
        typeTokens(), 0, typeTokenCount - 1, resolvedArgumentType)
    If resolvedArgumentType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0
    Dim resultType As String = resolvedArgumentType.freeBasicType
    If resultType = "" OrElse resultType = "void" Then Return 0

    parser.position = typeEnd + 1
    parser.hasFunctionCall = -1
    If UCase(resultType) = "CLONGDOUBLE" Then
        ' CLongDouble is byte-backed, so the compiler's aggregate va_arg path
        ' does not use C's native long-double argument class.
        value.text = "fb_LongDoubleVaArg(" & vaListValue.text & ")"
    Else
        value.text = "Cva_Arg(" & vaListValue.text & ", " & resultType & ")"
    End If
    value.typeName = resultType
    value.layoutType = resultType
    value.storageType = resultType
    value.cRecord = CBodyRecordName(parser.translation[0], parser.catalog[0], resultType)
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.isWholeCall = -1
    value.isFunctionDesignator = 0
    value.prelude = vaListValue.prelude
    Return -1
End Function

/' ------------------------------------------------------------------------- '/
/' Unary and postfix expressions                                             '/
/' ------------------------------------------------------------------------- '/

Private Function IsSimpleZeroArrayIndex(ByVal indexText As String) As Long
    Dim sawZero As Long = 0
    For position As Long = 1 To Len(indexText)
        Dim currentByte As Long = Asc(indexText, position)
        If IsSpaceByte(currentByte) <> 0 OrElse currentByte = Asc("(") OrElse _
           currentByte = Asc(")") Then Continue For
        If currentByte = Asc("0") AndAlso sawZero = 0 Then
            sawZero = -1
        ElseIf sawZero <> 0 AndAlso _
               (currentByte = Asc("u") OrElse currentByte = Asc("U") OrElse _
                currentByte = Asc("l") OrElse currentByte = Asc("L")) Then
            Continue For
        Else
            Return 0
        End If
    Next
    Return sawZero
End Function

Private Function SimpleVisibleValueIdentifier( _
    ByRef translation As C2fbTranslationContext, _
    ByVal identifier As String, _
    parameterNames() As String, parameterAliases() As String, _
    ByVal parameterCount As Long _
) As Long
    If ParameterAlias( _
        parameterNames(), parameterAliases(), parameterCount, identifier) <> "" Then _
        Return -1
    If CBodyExternalObjectIndex(translation, identifier) >= 0 Then Return -1
    If translation.target.profile = C2FB_TARGET_GENERIC AndAlso _
       GenericEnumMemberIndexInContext(translation, identifier) >= 0 Then Return -1
    If IsSQLiteConstantIdentifierInContext(translation, identifier) <> 0 Then Return -1
    Return 0
End Function

Private Function GenericStaticArrayElementSizeInBytes( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal freeBasicType As String _
) As Long
    If Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Mid(freeBasicType, 7)
    freeBasicType = NormalizeFbBodyType(catalog, freeBasicType)
    If InStr(freeBasicType, " Ptr") <> 0 OrElse _
       IsCBodyCallbackTypeInContext(translation, freeBasicType) <> 0 Then
        Return GenericHeaderPreprocessorSizeValue( _
            translation, "__SIZEOF_POINTER__")
    End If
    Dim byteSize As Long = GenericHeaderFreeBasicScalarSize( _
        translation, freeBasicType)
    If byteSize <= 0 Then _
        byteSize = GenericHeaderSimpleRecordSizeInBytes( _
            translation, freeBasicType)
    Return byteSize
End Function

Private Function CBodyGlobalArraySizeofExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceOperand As String, _
    ByRef freeBasicExpression As String, _
    ByRef sourceArrayName As String, _
    ByRef wholeArrayCount As Long, _
    ByRef isZeroArrayElement As Long _
) As Long
    freeBasicExpression = ""
    sourceArrayName = ""
    wholeArrayCount = 0
    isZeroArrayElement = 0
    sourceOperand = Trim(sourceOperand)
    Dim nameEnd As Long = 1
    If nameEnd > Len(sourceOperand) OrElse _
       IsIdentifierStart(Asc(sourceOperand, nameEnd)) = 0 Then Return 0
    nameEnd += 1
    While nameEnd <= Len(sourceOperand) AndAlso _
          IsIdentifierPart(Asc(sourceOperand, nameEnd)) <> 0
        nameEnd += 1
    Wend
    Dim sourceName As String = Left(sourceOperand, nameEnd - 1)
    SkipCSpaces(sourceOperand, nameEnd)
    Dim isArrayElement As Long = 0
    Dim arrayIndexText As String
    If nameEnd <= Len(sourceOperand) Then
        If Asc(sourceOperand, nameEnd) <> Asc("[") Then Return 0
        Dim bracketEnd As Long = nameEnd
        If ScanSimpleExpressionGroup( _
            sourceOperand, bracketEnd, Asc("["), Asc("]")) = 0 OrElse _
           Trim(Mid(sourceOperand, bracketEnd)) <> "" Then Return 0
        arrayIndexText = Trim(Mid( _
            sourceOperand, nameEnd + 1, bracketEnd - nameEnd - 2))
        isArrayElement = -1
    End If

    Dim elementType As String
    Dim arrayCount As Long
    Dim objectIndex As Long = CBodyExternalObjectIndex( _
        translation, sourceName)
    If objectIndex < 0 Then
        Dim reusedType As String
        Dim reusedArrayCount As Long
        If GenericStaticObjectLayoutInPolicy( _
            translation.genericC.policy, sourceName, _
            reusedType, reusedArrayCount) <> 0 Then
            Dim reusedElementSize As Long = _
                GenericStaticArrayElementSizeInBytes( _
                    translation, catalog, reusedType)
            If reusedElementSize > 0 Then
                If isArrayElement <> 0 Then
                    freeBasicExpression = "Cast(c2fb_size_t, " & _
                        Trim(Str(reusedElementSize)) & "ULL)"
                Else
                    Dim reusedArraySize As LongInt = _
                        CLngInt(reusedArrayCount) * reusedElementSize
                    freeBasicExpression = "Cast(c2fb_size_t, " & _
                        Trim(Str(reusedArraySize)) & "ULL)"
                End If
            ElseIf isArrayElement <> 0 Then
                freeBasicExpression = "Cast(c2fb_size_t, SizeOf(" & _
                    reusedType & "))"
            Else
                freeBasicExpression = "Cast(c2fb_size_t, (" & _
                    Trim(Str(reusedArrayCount)) & "ULL * SizeOf(" & _
                    reusedType & ")))"
            End If
            sourceArrayName = sourceName
            If isArrayElement <> 0 Then
                isZeroArrayElement = _
                    IsSimpleZeroArrayIndex(arrayIndexText)
            Else
                wholeArrayCount = reusedArrayCount
            End If
            Return -1
        End If

        ' Generic-header objects, including module-static arrays, live in the
        ' shared symbol table rather than the body external-object table.
        ' Let FreeBASIC apply its own record layout for these emitted types.
        Dim symbolIndex As Long = _
            GenericHeaderSymbolIndexInContext(translation, sourceName)
        If symbolIndex < 0 Then Return 0
        With translation.symbolTable.symbols(symbolIndex)
            If .kind <> GENERIC_SYMBOL_OBJECT OrElse _
               .genericHeader.unsizedArray <> 0 OrElse _
               .genericHeader.arrayCount <= 0 OrElse _
               .genericHeader.freeBasicType = "" Then Return 0
            elementType = .genericHeader.freeBasicType
            arrayCount = .genericHeader.arrayCount
        End With
        Dim symbolElementSize As Long = _
            GenericStaticArrayElementSizeInBytes( _
                translation, catalog, elementType)
        If symbolElementSize > 0 Then
            If isArrayElement <> 0 Then
                freeBasicExpression = "Cast(c2fb_size_t, " & _
                    Trim(Str(symbolElementSize)) & "ULL)"
            Else
                Dim symbolArraySize As LongInt = _
                    CLngInt(arrayCount) * symbolElementSize
                freeBasicExpression = "Cast(c2fb_size_t, " & _
                    Trim(Str(symbolArraySize)) & "ULL)"
            End If
        ElseIf isArrayElement <> 0 Then
            freeBasicExpression = "Cast(c2fb_size_t, SizeOf(" & _
                elementType & "))"
        Else
            freeBasicExpression = "Cast(c2fb_size_t, (" & _
                Trim(Str(arrayCount)) & "ULL * SizeOf(" & elementType & ")))"
        End If
        sourceArrayName = sourceName
        If isArrayElement <> 0 Then
            isZeroArrayElement = IsSimpleZeroArrayIndex(arrayIndexText)
        Else
            wholeArrayCount = arrayCount
        End If
        Return -1
    End If
    elementType = translation.body.externalObjects(objectIndex).freeBasicType
    arrayCount = translation.body.externalObjects(objectIndex).arrayCount
    If translation.body.externalObjects(objectIndex).isArray = 0 OrElse _
       translation.body.externalObjects(objectIndex).isUnsizedArray <> 0 OrElse _
       translation.body.externalObjects(objectIndex).arrayRank <> 1 OrElse _
       arrayCount <= 0 OrElse elementType = "" Then Return 0

    If Left(elementType, 6) = "Const " Then elementType = Mid(elementType, 7)
    Dim sourceRecord As String = CBodyRecordName( _
        translation, catalog, elementType)
    If SimpleArithmeticKind(catalog, elementType) = 0 AndAlso _
       InStr(elementType, " Ptr") = 0 AndAlso _
       IsCBodyCallbackTypeInContext(translation, elementType) = 0 AndAlso _
       CBodyRecordSizeIsKnown(translation, catalog, sourceRecord) = 0 AndAlso _
       FbBodyRecordHasFieldModel(catalog, elementType) = 0 Then Return 0

    Dim bodyElementSize As Long = _
        GenericStaticArrayElementSizeInBytes( _
            translation, catalog, elementType)
    If bodyElementSize > 0 AndAlso isArrayElement <> 0 Then
        freeBasicExpression = "Cast(c2fb_size_t, " & _
            Trim(Str(bodyElementSize)) & "ULL)"
    ElseIf bodyElementSize > 0 Then
        Dim bodyArraySize As LongInt = _
            CLngInt(arrayCount) * bodyElementSize
        freeBasicExpression = "Cast(c2fb_size_t, " & _
            Trim(Str(bodyArraySize)) & "ULL)"
    ElseIf isArrayElement <> 0 Then
        freeBasicExpression = "Cast(c2fb_size_t, SizeOf(" & _
            elementType & "))"
    Else
        freeBasicExpression = "Cast(c2fb_size_t, (" & _
            Trim(Str(arrayCount)) & "ULL * SizeOf(" & elementType & ")))"
    End If
    sourceArrayName = sourceName
    If isArrayElement <> 0 Then
        isZeroArrayElement = IsSimpleZeroArrayIndex(arrayIndexText)
    Else
        wholeArrayCount = arrayCount
    End If
    Return -1
End Function

Private Function LowerCBodyAlignofType( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue _
) As Long
    If parser.context = 0 Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If Mid(parser.sourceText, parser.position, 1) <> "(" Then Return 0

    Dim groupEnd As Long = parser.position
    If ScanSimpleExpressionGroup( _
        parser.sourceText, groupEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim sourceType As String = Trim(Mid( _
        parser.sourceText, parser.position + 1, _
        groupEnd - parser.position - 2))
    If sourceType = "" Then Return 0
    Dim resolvedType As C2fbResolvedTypeModel
    Dim localFreeBasicType As String = SimpleBodyLocalType( _
        parser.context[0], sourceType)
    Dim localRecordTag As String = ""
    If Left(sourceType, Len("struct ")) = "struct " Then
        localRecordTag = Trim(Mid(sourceType, Len("struct ") + 1))
    ElseIf Left(sourceType, Len("union ")) = "union " Then
        localRecordTag = Trim(Mid(sourceType, Len("union ") + 1))
    End If
    If localFreeBasicType = "" AndAlso localRecordTag <> "" Then
        ' Block-scope C tags are registered without their struct/union keyword.
        localFreeBasicType = SimpleBodyLocalType( _
            parser.context[0], localRecordTag)
    End If
    If localFreeBasicType <> "" AndAlso _
       SimpleBodyLocalCType(parser.context[0], sourceType) = "" Then
        resolvedType.status = C2FB_TYPE_RESOLUTION_RESOLVED
        resolvedType.freeBasicType = localFreeBasicType
    Else
        Dim localCType As String = SimpleBodyLocalCType( _
            parser.context[0], sourceType)
        If localCType <> "" Then
            sourceType = localCType
        Else
            sourceType = MapCRecordTypePrefix( _
                parser.translation[0], parser.catalog[0], sourceType)
            If sourceType = "" Then Return 0
        End If

        Dim typeTokens() As String
        Dim typeTokenCount As Long
        TokenizeCDeclaration(sourceType, typeTokens(), typeTokenCount)
        If typeTokenCount = 0 Then Return 0
        ResolveC2fbTypeModel( _
            parser.translation[0], parser.catalog[0], typeTokens(), _
            0, typeTokenCount - 1, resolvedType)
        If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED AndAlso _
           IsIdentifierToken(sourceType) <> 0 Then
            ' Header-pass typedefs are present in the generated FreeBASIC
            ' type catalog even when the body pass has no C typedef model.
            Dim generatedPrefix As String = _
                parser.translation[0].genericC.policy.generatedNamePrefix
            If generatedPrefix = "" Then generatedPrefix = "c2fb_"
            Dim generatedType As String = generatedPrefix & sourceType
            Dim normalizedGeneratedType As String = NormalizeFbBodyType( _
                parser.catalog[0], generatedType)
            If normalizedGeneratedType <> generatedType Then
                resolvedType.status = C2FB_TYPE_RESOLUTION_RESOLVED
                resolvedType.freeBasicType = normalizedGeneratedType
            End If
        End If
    End If
    If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
       resolvedType.freeBasicType = "" OrElse _
       LCase(resolvedType.freeBasicType) = "void" Then Return 0

    parser.position = groupEnd
    value.typeName = "c2fb_size_t"
    value.layoutType = value.typeName
    value.storageType = value.typeName
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.isReadOnly = 0
    value.lValueText = ""
    value.isWholeCall = 0
    value.isFunctionDesignator = 0
    value.arrayCount = 0
    value.arrayBound = ""
    value.arrayElementType = ""
    If parser.unevaluated <> 0 Then
        value.text = "0"
        Return -1
    End If

    Dim probeName As String = "c2fb_alignof_probe_" & _
        parser.context->functionName & "_" & _
        Trim(Str(parser.context->alignofProbeSerial))
    parser.context->alignofProbeSerial += 1
    ' The field after one byte exposes the mapped type's ABI alignment.
    parser.context->generatedBodyHelpers &= _
        "Type " & probeName & Chr(10) & _
        "    alignPrefix As UByte" & Chr(10) & _
        "    alignValue As " & resolvedType.freeBasicType & Chr(10) & _
        "End Type" & Chr(10)
    value.text = "OffsetOf(" & probeName & ", alignValue)"
    Return -1
End Function

Private Function ParseSimpleParenthesizedPointerCastOwner( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If parser.position > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, parser.position) <> Asc("(") Then Return 0

    Dim outerGroupEnd As Long = parser.position
    If ScanSimpleExpressionGroup( _
        parser.sourceText, outerGroupEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim suffixPosition As Long = outerGroupEnd
    SkipCSpaces(parser.sourceText, suffixPosition)
    If Mid(parser.sourceText, suffixPosition, 2) <> "->" Then
        Dim wrappedExpression As String = Trim(Mid( _
            parser.sourceText, parser.position + 1, _
            outerGroupEnd - parser.position - 2))
        If InStr(wrappedExpression, "->") = 0 OrElse _
           (InStr(wrappedExpression, "struct") = 0 AndAlso _
            InStr(wrappedExpression, "union") = 0) Then Return 0

        ' The body statement parser can wrap a complete return expression in
        ' redundant parentheses. Unwrap this C pointer-member expression and
        ' parse it normally so the inner cast owner reaches the postfix parser.
        Dim originalSource As String = parser.sourceText
        Dim originalPosition As Long = parser.position
        Dim originalBooleanOperator As Long = parser.hasBooleanOperator
        Dim originalFunctionCall As Long = parser.hasFunctionCall
        Dim originalRuntimeValue As Long = parser.hasRuntimeValue
        Dim originalUnevaluated As Long = parser.unevaluated
        Dim originalNormalized As Long = parser.simpleGnuExpressionsNormalized
        Dim originalFailureCode As String
        Dim originalFailureMessage As String
        If parser.context <> 0 Then
            originalFailureCode = parser.context->failureCode
            originalFailureMessage = parser.context->failureMessage
        End If

        parser.sourceText = wrappedExpression
        parser.position = 1
        Dim wrappedValue As SimpleExpressionValue
        Dim wrappedStatus As Long = ParseSimpleUnaryValue( _
            parser, wrappedValue, depth + 1, callableNames(), callableCount, _
            parameterNames(), parameterAliases(), parameterTypes(), parameterCount)
        SkipCSpaces(parser.sourceText, parser.position)
        Dim fullyParsed As Long = CInt( _
            wrappedStatus <> 0 AndAlso parser.position > Len(parser.sourceText))
        parser.sourceText = originalSource
        If fullyParsed <> 0 Then
            parser.position = outerGroupEnd
            value = wrappedValue
            Return -1
        End If

        parser.position = originalPosition
        parser.hasBooleanOperator = originalBooleanOperator
        parser.hasFunctionCall = originalFunctionCall
        parser.hasRuntimeValue = originalRuntimeValue
        parser.unevaluated = originalUnevaluated
        parser.simpleGnuExpressionsNormalized = originalNormalized
        If parser.context <> 0 Then
            parser.context->failureCode = originalFailureCode
            parser.context->failureMessage = originalFailureMessage
        End If
        Return 0
    End If

    Dim castExpression As String = Trim(Mid( _
        parser.sourceText, parser.position + 1, _
        outerGroupEnd - parser.position - 2))
    Dim castTypePosition As Long = 1
    Dim castType As String
    Dim isPointerCast As Long
    Dim castStatus As Long = ReadSimpleCTypeCast( _
        parser.translation[0], parser.catalog[0], castExpression, _
        castTypePosition, castType, isPointerCast, 0, parser.context)
    If castStatus = 0 Then
        ' Parentheses before -> can group an assignment expression, such as
        ' (node = *pnode)->member. Leave non-casts to the ordinary expression
        ' parser instead of recording a failed cast diagnostic here.
        Return 0
    End If
    If isPointerCast = 0 OrElse Right(castType, 4) <> " Ptr" Then
        If parser.context <> 0 Then _
            RecordSimpleBodyFailure( _
                parser.context[0], "unresolved-parenthesized-pointer-cast", _
                "could not resolve pointer cast before member access: " & _
                Left(castExpression, 100))
        Return 0
    End If

    ' A parenthesized C cast is a primary expression. Parse its contents first,
    ' then let the common postfix path handle ->member and any following fields.
    Dim originalSource As String = parser.sourceText
    Dim originalPosition As Long = parser.position
    Dim originalBooleanOperator As Long = parser.hasBooleanOperator
    Dim originalFunctionCall As Long = parser.hasFunctionCall
    Dim originalRuntimeValue As Long = parser.hasRuntimeValue
    Dim originalUnevaluated As Long = parser.unevaluated
    Dim originalNormalized As Long = parser.simpleGnuExpressionsNormalized
    Dim originalFailureCode As String
    Dim originalFailureMessage As String
    If parser.context <> 0 Then
        originalFailureCode = parser.context->failureCode
        originalFailureMessage = parser.context->failureMessage
    End If

    parser.sourceText = castExpression
    parser.position = 1
    Dim castOwner As SimpleExpressionValue
    Dim parseStatus As Long = ParseSimpleUnaryValue( _
        parser, castOwner, depth + 1, callableNames(), callableCount, _
        parameterNames(), parameterAliases(), parameterTypes(), parameterCount)
    SkipCSpaces(parser.sourceText, parser.position)
    Dim fullyParsed As Long = CInt( _
        parseStatus <> 0 AndAlso parser.position > Len(parser.sourceText))

    parser.sourceText = originalSource
    If fullyParsed <> 0 Then
        parser.position = outerGroupEnd
        value = castOwner
        Return -1
    End If

    parser.position = originalPosition
    parser.hasBooleanOperator = originalBooleanOperator
    parser.hasFunctionCall = originalFunctionCall
    parser.hasRuntimeValue = originalRuntimeValue
    parser.unevaluated = originalUnevaluated
    parser.simpleGnuExpressionsNormalized = originalNormalized
    If parser.context <> 0 Then
        parser.context->failureCode = originalFailureCode
        parser.context->failureMessage = originalFailureMessage
        RecordSimpleBodyFailure( _
            parser.context[0], "unsupported-parenthesized-pointer-cast-owner", _
            "could not parse cast owner before member access: " & _
            Left(castExpression, 100) & _
            IIf(parseStatus = 0, " (inner expression rejected)", _
                " (trailing tokens remain)"))
    End If
    Return 0
End Function

Private Function ParseSimpleUnaryValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position > Len(parser.sourceText) Then Return 0
    Dim c As Long = Asc(parser.sourceText, parser.position)
    value.arrayCount = 0
    value.arrayRank = 0
    value.isIncompleteArray = 0
    value.layoutType = ""
    value.isLayoutArray = 0
    value.isAlignedArray = 0
    value.isArrayStorageAlias = 0
    value.arrayElementType = ""
    value.arrayBound = ""
    value.arrayDimensions = ""
    value.arraySourceName = ""
    value.isArrayElementZero = 0
    value.isPointerToArray = 0
    value.pointerToArrayElementCount = 0
    value.pointerCount = 0
    value.volatileMask = 0
    value.volatileReadLowered = 0
    value.sizeOfArraySourceName = ""
    value.sizeOfArrayElementSourceName = ""
    value.sizeOfArrayCount = 0
    value.cRecord = ""
    value.lValueText = ""
    value.isWholeCall = 0
    value.isFunctionDesignator = 0
    value.logicalOperator = ""
    value.logicalCondition = ""
    value.prelude = ""
    value.storageType = ""
    value.isReadOnly = 0
    value.bitWidth = -1
    value.bitOffset = 0
    value.bitStorageText = ""
    value.bitFieldOwnerText = ""
    value.bitFieldOwnerType = ""
    value.bitFieldName = ""
    value.bitFieldOwnerIsPointer = 0
    value.isDirectBitField = 0
    value.isPackedBitField = 0
    value.isUnsignedBitField = 0
    value.isSignedBitField = 0
    If InStr("!~+-*&", Chr(c)) <> 0 Then
        If c = Asc("&") Then
            Dim compoundLiteralStatus As Long = _
                ParseSimpleAddressedCompoundLiteralValue( _
                    parser, value, depth, callableNames(), callableCount, _
                    parameterNames(), parameterAliases(), parameterTypes(), _
                    parameterCount)
            If compoundLiteralStatus = -1 Then Return -1
            If compoundLiteralStatus <> 0 Then Return 0
        End If
        If Mid(parser.sourceText, parser.position, 2) = "++" OrElse _
           Mid(parser.sourceText, parser.position, 2) = "--" Then
            Dim isDecrement As Long = (Mid(parser.sourceText, parser.position, 2) = "--")
            parser.position += 2
            If ParseSimpleUnaryValue(parser, value, depth + 1, callableNames(), callableCount, _
                                     parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
            Return ApplySimpleIncrement(parser, value, isDecrement, 0)
        End If
        parser.position += 1
        Dim operand As SimpleExpressionValue
        If ParseSimpleUnaryValue(parser, operand, depth + 1, callableNames(), callableCount, _
                                 parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
        value.isLValue = 0
        value.prelude = operand.prelude
        Select Case c
        Case Asc("!")
            value.text = SimpleBooleanValue(operand.text & " = 0")
            value.typeName = "c2fb_c_int"
            parser.hasBooleanOperator = -1
        Case Asc("&")
            If operand.isIncompleteArray <> 0 Then Return 0
            If operand.isArrayStorageAlias <> 0 Then
                If parser.targetType <> "Any Ptr" AndAlso _
                   parser.targetType <> "Const Any Ptr" Then Return 0
                value = operand
                value.text = "CPtr(" & parser.targetType & ", @(" & _
                    operand.text & "))"
                value.typeName = parser.targetType
                value.layoutType = parser.targetType
                value.storageType = parser.targetType
                value.cRecord = ""
                value.isLValue = 0
                value.isArrayStorageAlias = 0
                value.arrayBound = ""
                value.arrayElementType = ""
                value.isLayoutArray = 0
                value.lValueText = ""
                Return -1
            End If
            If operand.isAddressAccessor <> 0 Then
                value = operand
                value.isAddressAccessor = 0
                value.isLValue = 0
                Return -1
            End If
            If operand.isFunctionDesignator <> 0 Then
                value = operand
                value.isFunctionDesignator = 0
                Return -1
            End If
            If operand.isLayoutArray = 0 AndAlso _
               (operand.arrayCount > 0 OrElse operand.arrayBound <> "") Then
                If parser.targetType <> "Any Ptr" AndAlso _
                   parser.targetType <> "Const Any Ptr" Then Return 0
                value = operand
                value.text = "CPtr(" & parser.targetType & ", " & operand.text & ")"
                value.typeName = parser.targetType
                value.layoutType = parser.targetType
                value.storageType = parser.targetType
                value.cRecord = ""
                value.isLValue = 0
                value.isAddressAccessor = 0
                value.isWholeCall = 0
                value.arrayCount = 0
                value.arrayRank = 0
                value.arrayBound = ""
                value.isIncompleteArray = 0
                value.isLayoutArray = 0
                value.arrayElementType = ""
                value.arrayDimensions = ""
                value.arraySourceName = ""
                value.isArrayElementZero = 0
                value.lValueText = ""
                Return -1
            End If
            If operand.isLValue = 0 OrElse operand.bitWidth >= 0 Then Return 0
            Dim storage As String = operand.text
            If operand.lValueText <> "" Then storage = operand.lValueText
            If operand.arrayBound <> "" OrElse operand.arrayCount > 0 OrElse _
               operand.isLayoutArray <> 0 Then storage &= "(0)"
            value.text = "@(" & storage & ")"
            If Len(operand.typeName) <> 0 Then value.typeName = operand.typeName & " Ptr"
            If InStr(value.typeName, " Ptr") <> 0 Then value.text = "CPtr(" & value.typeName & ", " & value.text & ")"
            value.cRecord = operand.cRecord
            value.pointerCount = operand.pointerCount + 1
            value.volatileMask = operand.volatileMask
        Case Asc("*")
            If IsCBodyCallbackTypeInContext( _
                parser.translation[0], operand.typeName) <> 0 Then
                ' Dereferencing a C function pointer produces a function
                ' designator. FreeBASIC calls the typed callback directly.
                value = operand
                value.isLValue = 0
                value.lValueText = ""
                value.isFunctionDesignator = -1
                Return -1
            End If
            value.isIncompleteArray = 0
            value.typeName = SimplePointeeType(operand.typeName)
            If value.typeName = "Any" Then Return 0
            value.text = "(*" & SimpleCharacterPointer(operand) & ")"
            value.isLValue = -1
            value.layoutType = SimplePointeeType(operand.layoutType)
            value.storageType = value.layoutType
            value.lValueText = value.text
            value.cRecord = operand.cRecord
            value.pointerCount = operand.pointerCount - 1
            value.volatileMask = operand.volatileMask
            ' A pointer-to-const scalar yields read-only data. With one more
            ' pointer level, dereferencing yields the writable pointer slot.
            value.isReadOnly = CInt(Left(operand.typeName, 6) = "Const " AndAlso _
                                    InStr(value.typeName, " Ptr") = 0)
        Case Else
            Dim promotedType As String = SimpleArithmeticType(SimpleArithmeticKind(parser.catalog[0], operand.typeName))
            If c = Asc("~") AndAlso _
               SimpleArithmeticKindIsFloating( _
                   SimpleArithmeticKind(parser.catalog[0], promotedType)) <> 0 Then Return 0
            Dim operatorText As String = IIf(c = Asc("~"), "Not ", Chr(c))
            value.text = "(" & operatorText & SimpleValueCast(parser.translation[0], parser.catalog[0], operand, promotedType) & ")"
            value.typeName = promotedType
            If Len(promotedType) <> 0 AndAlso promotedType <> "CLongDouble" Then _
                value.text = "Cast(" & promotedType & ", " & value.text & ")"
            value.text = SimpleFloatingValue(value.text, promotedType)
        End Select
        Return -1
    End If

    If c = Asc("(") Then
        Dim castPostfixStatus As Long = _
            ParseSimpleParenthesizedPointerCastOwner( _
                parser, value, depth, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                parameterCount)
        If castPostfixStatus = 0 Then
        Dim assertValueStatus As Long = _
            TranslateSimpleAssertExpansionValue( _
                parser, value, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                parameterCount)
        If assertValueStatus <> 0 Then Return assertValueStatus
        Dim arrayLiteralStatus As Long = _
            ParseSimpleArrayCompoundLiteralValue( _
                parser, value, depth, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                parameterCount)
        If arrayLiteralStatus <> -1 Then
            If arrayLiteralStatus <> 0 Then Return 0
            Dim recordLiteralStatus As Long = _
                ParseSimpleRecordCompoundLiteralValue( _
                    parser, value, depth, callableNames(), callableCount, _
                    parameterNames(), parameterAliases(), parameterTypes(), _
                    parameterCount)
            If recordLiteralStatus <> -1 Then
                If recordLiteralStatus <> 0 Then Return 0
        Dim castPosition As Long = parser.position
        Dim castType As String
        Dim isPointer As Long = 0
        Dim castNameIsValue As Long = 0
        Dim castGroupEnd As Long = parser.position
        If ScanSimpleExpressionGroup( _
            parser.sourceText, castGroupEnd, Asc("("), Asc(")")) <> 0 Then
            Dim castName As String = Trim(Mid( _
                parser.sourceText, parser.position + 1, _
                castGroupEnd - parser.position - 2))
            If IsIdentifierToken(castName) <> 0 Then _
                castNameIsValue = SimpleVisibleValueIdentifier( _
                    parser.translation[0], castName, parameterNames(), _
                    parameterAliases(), parameterCount)
        End If
        Dim parsedCastValue As Long = 0
        If castNameIsValue = 0 AndAlso _
           ReadSimpleCTypeCast(parser.translation[0], parser.catalog[0], _
               parser.sourceText, castPosition, castType, isPointer, 0, _
               parser.context) <> 0 Then
            parser.position = castPosition
            SkipCSpaces(parser.sourceText, parser.position)
            If parser.unevaluated <> 0 AndAlso _
               Mid(parser.sourceText, parser.position, 1) = "{" AndAlso _
               SimpleArithmeticKind(parser.catalog[0], castType) <> 0 Then
                Dim literalEnd As Long = parser.position
                If ScanSimpleExpressionGroup( _
                    parser.sourceText, literalEnd, Asc("{"), Asc("}")) = 0 Then _
                    Return 0
                ' Generic selection and sizeof need only the compound literal's
                ' scalar type; C has already checked its initializer.
                parser.position = literalEnd
                value.text = "0"
                value.typeName = castType
                value.layoutType = NormalizeFbBodyType( _
                    parser.catalog[0], castType)
                value.storageType = castType
                value.cRecord = CBodyRecordName( _
                    parser.translation[0], parser.catalog[0], value.layoutType)
                value.isLValue = 0
                value.isFunctionDesignator = 0
                value.arrayCount = 0
                value.arrayBound = ""
                Return -1
            End If
            If parser.unevaluated = 0 AndAlso _
               Mid(parser.sourceText, parser.position, 1) = "{" AndAlso _
               SimpleArithmeticKind(parser.catalog[0], castType) <> 0 Then
                parser.position += 1
                SkipCSpaces(parser.sourceText, parser.position)
                Dim literalOperand As SimpleExpressionValue
                If ParseSimpleExpressionValue( _
                    parser, literalOperand, 2, depth + 1, callableNames(), _
                    callableCount, parameterNames(), parameterAliases(), _
                    parameterTypes(), parameterCount) = 0 Then Return 0
                SkipCSpaces(parser.sourceText, parser.position)
                If Mid(parser.sourceText, parser.position, 1) = "," Then
                    parser.position += 1
                    SkipCSpaces(parser.sourceText, parser.position)
                End If
                If Mid(parser.sourceText, parser.position, 1) <> "}" Then Return 0
                parser.position += 1
                value.text = SimpleValueCast( _
                    parser.translation[0], parser.catalog[0], _
                    literalOperand, castType)
                If value.text = "" Then Return 0
                value.typeName = castType
                value.layoutType = NormalizeFbBodyType( _
                    parser.catalog[0], castType)
                value.storageType = castType
                value.cRecord = CBodyRecordName( _
                    parser.translation[0], parser.catalog[0], value.layoutType)
                value.isLValue = 0
                value.isFunctionDesignator = 0
                value.prelude = literalOperand.prelude
                Return -1
            End If
            Dim operand As SimpleExpressionValue
            If ParseSimpleUnaryValue(parser, operand, depth + 1, callableNames(), callableCount, _
                                     parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
            value.prelude = operand.prelude
            If castType = "void" Then
                If parser.unevaluated = 0 Then
                    If DiscardSimpleValue(parser, operand) = 0 Then Return 0
                    value.prelude = operand.prelude
                End If
                value.typeName = "void"
                Return -1
            End If
            If isPointer <> 0 Then
                Dim pointerOperand As String = operand.text
                Dim integerKind As Long = SimpleArithmeticKind(parser.catalog[0], operand.typeName)
                If SimpleArithmeticKindIsInteger(integerKind) <> 0 Then
                    ' CPtr cannot accept an integer wider than the target pointer.
                    ' Use the configured C size_t width to preserve the target address bits.
                    pointerOperand = "Cast(c2fb_size_t, " & pointerOperand & ")"
                End If
                If IsCBodyCallbackTypeInContext(parser.translation[0], castType) <> 0 AndAlso _
                   operand.isFunctionDesignator <> 0 Then
                    ' The port's internal declaration uses Any Ptr for this
                    ' callback slot. CPtr accepts a named pointer type, while
                    ' FreeBASIC cannot use an inline callback signature as a
                    ' CPtr target type.
                    value.text = "CPtr(Any Ptr, " & operand.text & ")"
                Else
                    value.text = "CPtr(" & castType & ", " & pointerOperand & ")"
                End If
            Else
                Dim operandKind As Long = SimpleArithmeticKind(parser.catalog[0], operand.typeName)
                Dim castKind As Long = SimpleArithmeticKind(parser.catalog[0], castType)
                Dim operandText As String = operand.text
                If operandKind = 0 AndAlso castKind > 0 AndAlso _
                   (InStr(operand.typeName, " Ptr") <> 0 OrElse _
                    IsCBodyCallbackTypeInContext(parser.translation[0], operand.typeName) <> 0) Then
                    ' Preserve the target address width before applying the C cast width.
                    operandText = "Cast(c2fb_size_t, " & operandText & ")"
                    operandKind = 4
                End If
                If operandKind = 0 OrElse castKind = 0 Then Return 0
                ' FreeBASIC float-to-integer casts round. C discards the fraction
                ' for in-range values, so Fix must precede an integer cast.
                If SimpleFloatingCastNeedsFix(operandKind) <> 0 AndAlso _
                   SimpleArithmeticKindIsInteger(castKind) <> 0 Then _
                    operandText = "Fix(" & operandText & ")"
                If NormalizeFbBodyType( _
                    parser.catalog[0], castType) = "CLongDouble" OrElse _
                   operandKind = 7 Then
                    value.text = SimpleValueCast( _
                        parser.translation[0], parser.catalog[0], operand, castType)
                    If value.text = "" Then Return 0
                Else
                    value.text = "Cast(" & castType & ", " & operandText & ")"
                End If
                value.text = SimpleFloatingValue(value.text, castType)
            End If
            value.typeName = castType
            value.layoutType = NormalizeFbBodyType( _
                parser.catalog[0], castType)
            value.storageType = castType
            value.cRecord = CBodyRecordName( _
                parser.translation[0], parser.catalog[0], value.layoutType)
            value.isLValue = 0
            value.isFunctionDesignator = 0
            parsedCastValue = -1
        End If
        If parsedCastValue = 0 Then
            parser.position += 1
            If ParseSimpleExpressionValue(parser, value, 1, depth + 1, callableNames(), callableCount, _
                                          parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
            SkipCSpaces(parser.sourceText, parser.position)
            If Mid(parser.sourceText, parser.position, 1) <> ")" Then Return 0
            parser.position += 1
            value.text = "(" & value.text & ")"
            If value.lValueText <> "" Then value.lValueText = "(" & value.lValueText & ")"
        End If
            End If
        End If
        End If
    ElseIf (c >= Asc("0") AndAlso c <= Asc("9")) OrElse _
           (c = Asc(".") AndAlso parser.position < Len(parser.sourceText) AndAlso _
            Asc(parser.sourceText, parser.position + 1) >= Asc("0") AndAlso _
            Asc(parser.sourceText, parser.position + 1) <= Asc("9")) Then
        If ReadSimpleFloatingValue(parser, value) = 0 Then
            If ReadSimpleIntegerValue(parser, value) = 0 Then Return 0
        End If
    ElseIf c = Asc("L") AndAlso _
           Mid(parser.sourceText, parser.position + 1, 1) = Chr(34) Then
        If ReadSimpleWideStringValue(parser, value) = 0 Then Return 0
    ElseIf c = Asc("'") OrElse _
           (c = Asc("L") AndAlso _
            Mid(parser.sourceText, parser.position + 1, 1) = "'") Then
        If ReadSimpleCharacterValue(parser, value) = 0 Then Return 0
    ElseIf c = Asc("""") Then
        If ReadSimpleStringValue(parser, value) = 0 Then Return 0
    ElseIf IsIdentifierStart(c) <> 0 Then
        If Mid(parser.sourceText, parser.position, Len("__extension__")) = _
           "__extension__" Then
            Dim obstackFreeStatus As Long = _
                ParseSimpleObstackFreeStatementExpression( _
                    parser, value, parser.position, depth, callableNames(), _
                    callableCount, parameterNames(), parameterAliases(), _
                    parameterTypes(), parameterCount)
            If obstackFreeStatus <> 0 Then Return obstackFreeStatus
            Dim obstackPointerGrowStatus As Long = _
                ParseSimpleObstackPointerGrowStatementExpression( _
                    parser, value, parser.position, depth, callableNames(), _
                    callableCount, parameterNames(), parameterAliases(), _
                    parameterTypes(), parameterCount)
            If obstackPointerGrowStatus <> 0 Then _
                Return obstackPointerGrowStatus
            Dim obstackSingleGrowStatus As Long = _
                ParseSimpleObstackSingleGrowStatementExpression( _
                    parser, value, parser.position, depth, callableNames(), _
                    callableCount, parameterNames(), parameterAliases(), _
                    parameterTypes(), parameterCount)
            If obstackSingleGrowStatus <> 0 Then _
                Return obstackSingleGrowStatus
            Dim obstackFinishStatus As Long = _
                ParseSimpleObstackFinishStatementExpression( _
                    parser, value, parser.position, depth, callableNames(), _
                    callableCount, parameterNames(), parameterAliases(), _
                    parameterTypes(), parameterCount)
            If obstackFinishStatus <> 0 Then Return obstackFinishStatus
            Dim obstackBlankStatus As Long = _
                ParseSimpleObstackBlankStatementExpression( _
                    parser, value, parser.position, depth, callableNames(), _
                    callableCount, parameterNames(), parameterAliases(), _
                    parameterTypes(), parameterCount)
            If obstackBlankStatus <> 0 Then Return obstackBlankStatus
            Dim obstackGrowStatus As Long = _
                ParseSimpleObstackGrowStatementExpression( _
                    parser, value, parser.position, depth, callableNames(), _
                    callableCount, parameterNames(), parameterAliases(), _
                    parameterTypes(), parameterCount)
            If obstackGrowStatus <> 0 Then Return obstackGrowStatus
        End If
        Dim start As Long = parser.position
        parser.position += 1
        While parser.position <= Len(parser.sourceText) AndAlso _
              IsIdentifierPart(Asc(parser.sourceText, parser.position)) <> 0
            parser.position += 1
        Wend
        Dim identifier As String = Mid(parser.sourceText, start, parser.position - start)
        SkipCSpaces(parser.sourceText, parser.position)
        If identifier = "nullptr" AndAlso _
           SimpleVisibleValueIdentifier( _
               parser.translation[0], identifier, parameterNames(), _
               parameterAliases(), parameterCount) = 0 AndAlso _
           CBodyProcedureIndex(parser.translation[0], identifier) < 0 AndAlso _
           C2fbNameListContains( _
               callableNames(), callableCount, identifier) = 0 Then
            ' C23 nullptr has a dedicated C type. The expression layer keeps
            ' its null value as Any Ptr so normal pointer and callback casts
            ' can apply the destination signature at the use site.
            value.text = "CPtr(Any Ptr, 0)"
            value.typeName = "Any Ptr"
            value.layoutType = value.typeName
            value.storageType = value.typeName
            value.pointerCount = 1
            value.isLValue = 0
            value.isFunctionDesignator = 0
            Return -1
        End If
        Dim c23AlignofKeyword As Long = CInt( _
            identifier = "alignof" AndAlso _
            SimpleVisibleValueIdentifier( _
                parser.translation[0], identifier, parameterNames(), _
                parameterAliases(), parameterCount) = 0 AndAlso _
            CBodyProcedureIndex(parser.translation[0], identifier) < 0 AndAlso _
            C2fbNameListContains( _
                callableNames(), callableCount, identifier) = 0)
        If identifier = "_Alignof" OrElse identifier = "__alignof" OrElse _
           identifier = "__alignof__" OrElse c23AlignofKeyword <> 0 Then
            Dim alignofStatus As Long = _
                LowerCBodyAlignofType(parser, value)
            If alignofStatus <> 0 Then Return alignofStatus
        End If
        If identifier = "__builtin_offsetof" Then
            If Mid(parser.sourceText, parser.position, 1) <> "(" Then Return 0
            parser.position += 1
            SkipCSpaces(parser.sourceText, parser.position)
            If parser.position > Len(parser.sourceText) OrElse _
               IsIdentifierStart(Asc(parser.sourceText, parser.position)) = 0 Then Return 0
            Dim typeStart As Long = parser.position
            parser.position += 1
            While parser.position <= Len(parser.sourceText) AndAlso _
                  IsIdentifierPart(Asc(parser.sourceText, parser.position)) <> 0
                parser.position += 1
            Wend
            Dim sourceRecord As String = Mid(parser.sourceText, typeStart, parser.position - typeStart)
            If sourceRecord = "struct" OrElse sourceRecord = "union" Then
                SkipCSpaces(parser.sourceText, parser.position)
                If parser.position > Len(parser.sourceText) OrElse _
                   IsIdentifierStart(Asc(parser.sourceText, parser.position)) = 0 Then Return 0
                typeStart = parser.position
                parser.position += 1
                While parser.position <= Len(parser.sourceText) AndAlso _
                      IsIdentifierPart(Asc(parser.sourceText, parser.position)) <> 0
                    parser.position += 1
                Wend
                sourceRecord = Mid(parser.sourceText, typeStart, parser.position - typeStart)
            End If
            SkipCSpaces(parser.sourceText, parser.position)
            If Mid(parser.sourceText, parser.position, 1) <> "," Then Return 0
            parser.position += 1
            SkipCSpaces(parser.sourceText, parser.position)
            If parser.position > Len(parser.sourceText) OrElse _
               IsIdentifierStart(Asc(parser.sourceText, parser.position)) = 0 Then Return 0
            Dim fieldStart As Long = parser.position
            parser.position += 1
            While parser.position <= Len(parser.sourceText) AndAlso _
                  IsIdentifierPart(Asc(parser.sourceText, parser.position)) <> 0
                parser.position += 1
            Wend
            Dim fieldName As String = Mid(parser.sourceText, fieldStart, parser.position - fieldStart)
            SkipCSpaces(parser.sourceText, parser.position)
            Dim fieldArrayIndex As Long = -1
            If Mid(parser.sourceText, parser.position, 1) = "[" Then
                ' Element zero has the same address as the array member.
                parser.position += 1
                SkipCSpaces(parser.sourceText, parser.position)
                If Mid(parser.sourceText, parser.position, 1) <> "0" Then Return 0
                parser.position += 1
                SkipCSpaces(parser.sourceText, parser.position)
                If Mid(parser.sourceText, parser.position, 1) <> "]" Then Return 0
                parser.position += 1
                fieldArrayIndex = 0
                SkipCSpaces(parser.sourceText, parser.position)
            End If
            If Mid(parser.sourceText, parser.position, 1) <> ")" Then Return 0
            parser.position += 1

            Dim localFbRecord As String = ""
            If parser.context <> 0 Then _
                localFbRecord = SimpleBodyLocalType( _
                    parser.context[0], sourceRecord)
            If localFbRecord <> "" Then
                ' Block-scope tags can be reused by separate functions with
                ' different field types. Their emitted local record is the
                ' authoritative layout for this offsetof expression.
                Dim localFbField As Long = LookupFbBodyField( _
                    parser.translation[0], parser.catalog[0], _
                    localFbRecord, fieldName)
                If localFbField < 0 Then Return 0
                If fieldArrayIndex = 0 AndAlso _
                   parser.catalog[0].bodyFields(localFbField).isArray = 0 Then _
                    Return 0
                Dim localOffsetFieldName As String = _
                    parser.catalog[0].bodyFields(localFbField).name
                If parser.catalog[0].bodyFields(localFbField).isArray <> 0 Then _
                    localOffsetFieldName &= "(0)"
                For fieldIndex As Long = localFbField + 1 To _
                    parser.catalog[0].bodyFieldCount - 1
                    If parser.catalog[0].bodyFields(fieldIndex).ownerName = _
                       localFbRecord Then Return 0
                Next
                value.text = "Cast(c2fb_size_t, OffsetOf(" & _
                    localFbRecord & ", " & localOffsetFieldName & "))"
                value.typeName = "c2fb_size_t"
                value.layoutType = value.typeName
                value.isLValue = 0
                value.isFunctionDesignator = 0
                Return -1
            End If
            Dim fbRecord As String = MappedFbBodyRecord(parser.translation[0], parser.catalog[0], sourceRecord)
            Dim cField As Long = CBodyRecordFieldIndex(parser.translation[0], parser.catalog[0], sourceRecord, fieldName)
            If cField < 0 Then
                Dim sourceRecordTag As String = _
                    CBodyRecordTagAliasInContext(parser.translation[0], sourceRecord)
                If sourceRecordTag <> "" Then _
                    cField = CBodyRecordFieldIndex( _
                        parser.translation[0], parser.catalog[0], _
                        sourceRecordTag, fieldName)
            End If
            If parser.context <> 0 Then
                ' A block-local record has only a SimpleBodyContext name
                ' mapping, not a file-scope C tag binding.
                Dim localFbRecord As String = _
                    SimpleBodyLocalType(parser.context[0], sourceRecord)
                If localFbRecord <> "" Then
                    If fbRecord = "" Then fbRecord = localFbRecord
                    If cField < 0 Then _
                        cField = CBodyRecordFieldIndex( _
                            parser.translation[0], parser.catalog[0], _
                            localFbRecord, fieldName)
                End If
            End If
            If cField < 0 AndAlso fbRecord <> "" Then _
                cField = CBodyRecordFieldIndexForMappedFbRecord( _
                    parser.translation[0], parser.catalog[0], fbRecord, fieldName)
            If fbRecord = "" Then
                If parser.context <> 0 Then _
                    RecordSimpleBodyFailure(parser.context[0], _
                        "unmapped-offsetof-record", _
                        "no FreeBASIC record layout for C type " & sourceRecord)
                Return 0
            End If
            If cField < 0 Then
                Dim aliasPointerCount As Long
                Dim aliasIsConst As Long
                Dim resolvedCRecord As String = LookupCBodyTypeAliasInContext( _
                    parser.translation[0], sourceRecord, aliasPointerCount, _
                    aliasIsConst)
                If resolvedCRecord = "" Then resolvedCRecord = "<unresolved>"
                If parser.context <> 0 Then _
                    RecordSimpleBodyFailure(parser.context[0], _
                        "unmapped-offsetof-field", _
                        "no C field " & sourceRecord & "." & fieldName & _
                        " (typedef target: " & resolvedCRecord & ")")
                Return 0
            End If
            If fieldArrayIndex = 0 AndAlso _
               parser.translation[0].body.recordFields(cField).isArray = 0 Then _
                Return 0
            Dim fbField As Long = LookupFbBodyField( _
                parser.translation[0], parser.catalog[0], fbRecord, fieldName, cField)
            If fbField < 0 Then
                Dim tailAccessorName As String = _
                    CBodyGenericFlexibleArrayAccessorName( _
                        parser.translation[0], parser.catalog[0], cField)
                If tailAccessorName = "" Then
                    If parser.context <> 0 Then _
                        RecordSimpleBodyFailure(parser.context[0], _
                            "unmapped-offsetof-field", _
                            "no FreeBASIC field " & fbRecord & "." & fieldName)
                    Return 0
                End If
                ' c2fb_size_t follows the FreeBASIC target's pointer width.
                ' Casting the address directly avoids an invalid 64-bit integer
                ' conversion on 32-bit targets.
                value.text = "Cast(c2fb_size_t, " & _
                    tailAccessorName & "(Cast(" & fbRecord & " Ptr, 0)))"
                value.typeName = "c2fb_size_t"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.isLValue = 0
                value.isFunctionDesignator = 0
                Return -1
            End If
            Dim cMemberIsArray As Long = _
                parser.translation[0].body.recordFields(cField).isArray
            Dim fbMemberIsArray As Long = _
                parser.catalog[0].bodyFields(fbField).isArray
            Dim cMemberArrayBound As String = _
                parser.translation[0].body.recordFields(cField).arrayBound
            If cMemberIsArray <> fbMemberIsArray Then Return 0
            If cMemberIsArray = 0 OrElse _
               (cMemberArrayBound <> "" AndAlso cMemberArrayBound <> "0") Then
                Dim offsetFieldName As String = _
                    parser.catalog[0].bodyFields(fbField).name
                If fbMemberIsArray <> 0 Then offsetFieldName &= "(0)"
                value.text = "Cast(c2fb_size_t, OffsetOf(" & fbRecord & ", " & _
                    offsetFieldName & "))"
                value.typeName = "c2fb_size_t"
                value.layoutType = value.typeName
                value.isLValue = 0
                value.isFunctionDesignator = 0
                Return -1
            End If
            Dim elementType As String = parser.catalog[0].bodyFields(fbField).typeName
            Dim sourceElementType As String = parser.translation[0].body.recordFields(cField).sourceType
            Dim elementLayoutMatches As Long = 0
            If CBodyRecordSizeIsKnown( _
                parser.translation[0], parser.catalog[0], sourceElementType) <> 0 AndAlso _
               CBodyRecordName( _
                   parser.translation[0], parser.catalog[0], elementType) = _
                   sourceElementType Then
                elementLayoutMatches = -1
            ElseIf parser.translation[0].body.recordFields(cField).pointerCount = 0 AndAlso _
                   CBodyRecordName( _
                       parser.translation[0], parser.catalog[0], sourceElementType) = "" AndAlso _
                   InStr(elementType, " Ptr") = 0 AndAlso _
                   CBodyCallbackIndexInContext( _
                       parser.translation[0], sourceElementType) < 0 AndAlso _
                   CBodyCallbackIndexInContext( _
                       parser.translation[0], elementType) < 0 Then
                Dim sourceElementLayoutType As String = CBodyFieldType( _
                    parser.translation[0], parser.catalog[0], cField, 0)
                If sourceElementLayoutType <> "" AndAlso _
                   LCase(NormalizeFbBodyType( _
                       parser.catalog[0], sourceElementLayoutType)) = _
                   LCase(NormalizeFbBodyType( _
                       parser.catalog[0], elementType)) Then
                    ' A zero-sized C tail uses a one-element FreeBASIC
                    ' placeholder. Scalar elements match when both type
                    ' models resolve to the same storage type.
                    elementLayoutMatches = -1
                End If
            ElseIf parser.translation[0].body.recordFields(cField).pointerCount > 0 AndAlso _
                   (parser.translation[0].body.recordFields(cField).arrayBound = "" OrElse _
                    parser.translation[0].body.recordFields(cField).arrayBound = "0") AndAlso _
                   (InStr(elementType, " Ptr") <> 0 OrElse _
                    IsCBodyCallbackTypeInContext( _
                        parser.translation[0], elementType) <> 0) Then
                ' A mapped flexible pointer array uses one FreeBASIC placeholder
                ' element. Both C data pointers and their mapped pointer fields
                ' have the target's pointer size, so removing that placeholder
                ' yields the C flexible member's starting offset.
                elementLayoutMatches = -1
            End If
            If elementLayoutMatches = 0 Then Return 0

            ' OffsetOf returns the flexible member's start directly. Do not
            ' subtract the placeholder size from SizeOf: the FreeBASIC record
            ' may have tail padding that is not part of C's flexible prefix.
            For fieldIndex As Long = cField + 1 To parser.translation[0].body.recordFieldCount - 1
                If parser.translation[0].body.recordFields(fieldIndex).ownerName = sourceRecord Then Return 0
            Next
            For fieldIndex As Long = fbField + 1 To parser.catalog[0].bodyFieldCount - 1
                If parser.catalog[0].bodyFields(fieldIndex).ownerName = fbRecord Then Return 0
            Next
            Dim offsetFieldName As String = _
                parser.catalog[0].bodyFields(fbField).name
            If fbMemberIsArray <> 0 Then offsetFieldName &= "(0)"
            value.text = "Cast(c2fb_size_t, OffsetOf(" & fbRecord & ", " & _
                offsetFieldName & "))"
            value.typeName = "c2fb_size_t"
            value.layoutType = value.typeName
            value.isLValue = 0
            value.isFunctionDesignator = 0
            Return -1
        End If
        If identifier = "sizeof" Then
            Dim operandType As String
            Dim typePosition As Long = parser.position
            Dim isPointer As Long
            Dim operand As SimpleExpressionValue
            Dim oldUnevaluated As Long = parser.unevaluated
            Dim oldHasCall As Long = parser.hasFunctionCall
            Dim oldHasBoolean As Long = parser.hasBooleanOperator
            parser.unevaluated = -1
            Dim arraySizeExpression As String
            If CBodyCastMemberArraySizeofExpression( _
                parser.translation[0], parser.catalog[0], _
                parser.sourceText, typePosition, arraySizeExpression) <> 0 OrElse _
               CBodyArrayTypeSizeInContext( _
                parser.translation[0], parser.catalog[0], _
                parser.sourceText, typePosition, _
                arraySizeExpression) <> 0 Then
                parser.position = typePosition
                value.text = arraySizeExpression
                value.typeName = "c2fb_size_t"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.isLValue = 0
                value.isFunctionDesignator = 0
                value.arrayCount = 0
                value.arrayBound = ""
                parser.unevaluated = oldUnevaluated
                parser.hasFunctionCall = oldHasCall
                parser.hasBooleanOperator = oldHasBoolean
                Return -1
            Else
                Dim staticOperandStart As Long = typePosition
                SkipCSpaces(parser.sourceText, staticOperandStart)
                If staticOperandStart <= Len(parser.sourceText) AndAlso _
                   IsIdentifierStart(Asc( _
                       parser.sourceText, staticOperandStart)) <> 0 Then
                    Dim staticOperandEnd As Long = staticOperandStart + 1
                    While staticOperandEnd <= Len(parser.sourceText) AndAlso _
                          IsIdentifierPart(Asc( _
                              parser.sourceText, staticOperandEnd)) <> 0
                        staticOperandEnd += 1
                    Wend
                    SkipCSpaces(parser.sourceText, staticOperandEnd)
                    If staticOperandEnd <= Len(parser.sourceText) AndAlso _
                       Asc(parser.sourceText, staticOperandEnd) = Asc("[") Then
                        Dim bracketEnd As Long = staticOperandEnd
                        If ScanSimpleExpressionGroup( _
                            parser.sourceText, bracketEnd, _
                            Asc("["), Asc("]")) <> 0 Then _
                            staticOperandEnd = bracketEnd
                    End If

                    Dim staticOperandName As String = Trim(Mid( _
                        parser.sourceText, staticOperandStart, _
                        staticOperandEnd - staticOperandStart))
                    Dim localValueAlias As String = ParameterAlias( _
                        parameterNames(), parameterAliases(), parameterCount, _
                        staticOperandName)
                    If localValueAlias = "" AndAlso _
                       GenericEnumMemberIndexInContext( _
                           parser.translation[0], staticOperandName) < 0 AndAlso _
                       CBodyProcedureIndex( _
                           parser.translation[0], staticOperandName) < 0 Then
                        Dim staticArraySourceName As String
                        Dim staticArrayCount As Long
                        Dim staticArrayElementZero As Long
                        If CBodyGlobalArraySizeofExpression( _
                               parser.translation[0], parser.catalog[0], _
                               staticOperandName, value.text, _
                               staticArraySourceName, staticArrayCount, _
                               staticArrayElementZero) <> 0 Then
                            parser.position = staticOperandEnd
                            value.typeName = "c2fb_size_t"
                            value.layoutType = value.typeName
                            value.storageType = value.typeName
                            value.isLValue = 0
                            value.isFunctionDesignator = 0
                            value.arrayCount = 0
                            value.arrayBound = ""
                            If staticArrayCount > 0 Then
                                value.sizeOfArraySourceName = _
                                    staticArraySourceName
                                value.sizeOfArrayCount = staticArrayCount
                            ElseIf staticArrayElementZero <> 0 Then
                                value.sizeOfArrayElementSourceName = _
                                    staticArraySourceName
                            End If
                            parser.unevaluated = oldUnevaluated
                            parser.hasFunctionCall = oldHasCall
                            parser.hasBooleanOperator = oldHasBoolean
                            Return -1
                        End If
                        Dim staticOperandSize As Long
                        If GenericModuleStaticSizeofOperandInContext( _
                            parser.translation[0], staticOperandName, _
                            staticOperandSize) <> 0 AndAlso _
                           staticOperandSize > 0 Then
                            parser.position = staticOperandEnd
                            value.text = "Cast(c2fb_size_t, " & _
                                Trim(Str(staticOperandSize)) & "ULL)"
                            value.typeName = "c2fb_size_t"
                            value.layoutType = value.typeName
                            value.storageType = value.typeName
                            value.isLValue = 0
                            value.isFunctionDesignator = 0
                            value.arrayCount = 0
                            value.arrayBound = ""
                            parser.unevaluated = oldUnevaluated
                            parser.hasFunctionCall = oldHasCall
                            parser.hasBooleanOperator = oldHasBoolean
                            Return -1
                        End If
                    End If
                End If

                Dim visibleValueIdentifier As Long = 0
                Dim visibleBlockValueIdentifier As Long = 0
                Dim localRecordType As String = ""
            Dim sizeofTypeName As String
            Dim sizeofTypeBytes As Long = 0
            Dim sizeofArraySourceName As String
            Dim sizeofArrayCount As Long
            Dim sizeofArrayElementZero As Long
                Dim operandGroupEnd As Long = typePosition
                If ScanSimpleExpressionGroup( _
                    parser.sourceText, operandGroupEnd, Asc("("), Asc(")")) <> 0 Then
                    Dim operandName As String = Trim(Mid( _
                        parser.sourceText, typePosition + 1, _
                        operandGroupEnd - typePosition - 2))
                    sizeofTypeName = operandName
                    If IsIdentifierToken(operandName) <> 0 Then
                        Dim localValueAlias As String = ParameterAlias( _
                            parameterNames(), parameterAliases(), parameterCount, _
                            operandName)
                        Dim globalEnumIndex As Long = _
                            GenericEnumMemberIndexInContext( _
                                parser.translation[0], operandName)
                        If localValueAlias <> "" OrElse _
                           globalEnumIndex >= 0 Then _
                            visibleBlockValueIdentifier = -1
                        If visibleBlockValueIdentifier <> 0 OrElse _
                           CBodyExternalObjectIndex( _
                               parser.translation[0], operandName) >= 0 Then
                            ' In C sizeof(x), a visible object named x takes
                            ' precedence over a case-folded FreeBASIC type name.
                            visibleValueIdentifier = -1
                        End If
                        If parser.context <> 0 Then _
                            localRecordType = SimpleBodyLocalType( _
                                parser.context[0], operandName)
                    ElseIf parser.context <> 0 Then
                        ' A block-scope record tag is written as "struct Tag"
                        ' or "union Tag" in a C sizeof type-name, while the
                        ' local type table indexes the tag alone.
                        Dim localRecordTokens() As String
                        Dim localRecordTokenCount As Long
                        TokenizeCDeclaration( _
                            operandName, localRecordTokens(), _
                            localRecordTokenCount)
                        If localRecordTokenCount >= 2 Then
                            Dim localTagIndex As Long = _
                                localRecordTokenCount - 2
                            If (localRecordTokens(localTagIndex) = "struct" OrElse _
                                localRecordTokens(localTagIndex) = "union") AndAlso _
                               IsIdentifierToken( _
                                   localRecordTokens(localTagIndex + 1)) <> 0 Then
                                localRecordType = SimpleBodyLocalType( _
                                    parser.context[0], _
                                    localRecordTokens(localTagIndex + 1))
                            End If
                        End If
                    End If
                End If

                If localRecordType <> "" Then
                    parser.position = operandGroupEnd
                    operand.typeName = localRecordType
                    operand.layoutType = localRecordType
                    operand.storageType = localRecordType
                    operand.cRecord = CBodyRecordName( _
                        parser.translation[0], parser.catalog[0], localRecordType)
                    operand.isLValue = 0
                    operandType = localRecordType
                ElseIf visibleBlockValueIdentifier = 0 AndAlso _
                       CBodyGlobalArraySizeofExpression( _
                           parser.translation[0], parser.catalog[0], _
                           sizeofTypeName, value.text, _
                           sizeofArraySourceName, sizeofArrayCount, _
                           sizeofArrayElementZero) <> 0 Then
                    parser.position = operandGroupEnd
                    value.typeName = "c2fb_size_t"
                    value.layoutType = value.typeName
                    value.storageType = value.typeName
                    value.isLValue = 0
                    value.isFunctionDesignator = 0
                    If sizeofArrayCount > 0 Then
                        value.sizeOfArraySourceName = sizeofArraySourceName
                        value.sizeOfArrayCount = sizeofArrayCount
                    ElseIf sizeofArrayElementZero <> 0 Then
                        value.sizeOfArrayElementSourceName = _
                            sizeofArraySourceName
                    End If
                    parser.unevaluated = oldUnevaluated
                    parser.hasFunctionCall = oldHasCall
                    parser.hasBooleanOperator = oldHasBoolean
                    Return -1
                ElseIf visibleBlockValueIdentifier = 0 AndAlso _
                       GenericModuleStaticSizeofOperandInContext( _
                           parser.translation[0], sizeofTypeName, _
                           sizeofTypeBytes) <> 0 AndAlso sizeofTypeBytes > 0 Then
                    ' Static arrays emitted with the generic header retain C
                    ' storage metadata separately from their FreeBASIC names.
                    ' Fold their whole-object or one-dimensional element size
                    ' before array decay loses that information.
                    parser.position = operandGroupEnd
                    value.text = "Cast(c2fb_size_t, " & _
                        Trim(Str(sizeofTypeBytes)) & "ULL)"
                    value.typeName = "c2fb_size_t"
                    value.layoutType = value.typeName
                    value.storageType = value.typeName
                    value.isLValue = 0
                    value.isFunctionDesignator = 0
                    parser.unevaluated = oldUnevaluated
                    parser.hasFunctionCall = oldHasCall
                    parser.hasBooleanOperator = oldHasBoolean
                    Return -1
                ElseIf visibleValueIdentifier <> 0 Then
                    ' Parse the identifier inside the group directly. Passing
                    ' `(event)` back through unary parsing would try the same
                    ' ambiguous type-name interpretation again.
                    parser.position = typePosition + 1
                    If ParseSimpleExpressionValue( _
                        parser, operand, 1, depth + 1, callableNames(), _
                        callableCount, parameterNames(), parameterAliases(), _
                        parameterTypes(), parameterCount) = 0 Then Return 0
                    SkipCSpaces(parser.sourceText, parser.position)
                    If Mid(parser.sourceText, parser.position, 1) <> ")" Then _
                        Return 0
                    parser.position += 1
                    operandType = operand.typeName
                ElseIf sizeofTypeName <> "" AndAlso _
                       parser.translation[0].target.profile = C2FB_TARGET_GENERIC AndAlso _
                       GenericModuleStaticTypeSizeInContext( _
                           parser.translation[0], sizeofTypeName, _
                           sizeofTypeBytes) <> 0 AndAlso sizeofTypeBytes > 0 Then
                    ' Some C typedefs map to opaque FreeBASIC storage names.
                    ' Their sizeof result is still a target-ABI integer
                    ' constant, so fold it before emitting a BASIC SizeOf.
                    parser.position = operandGroupEnd
                    value.text = "Cast(c2fb_size_t, " & _
                        Trim(Str(sizeofTypeBytes)) & "ULL)"
                    value.typeName = "c2fb_size_t"
                    value.layoutType = value.typeName
                    value.storageType = value.typeName
                    value.isLValue = 0
                    value.isFunctionDesignator = 0
                    parser.unevaluated = oldUnevaluated
                    parser.hasFunctionCall = oldHasCall
                    parser.hasBooleanOperator = oldHasBoolean
                    Return -1
                ElseIf ReadSimpleCTypeCast( _
                       parser.translation[0], parser.catalog[0], _
                       parser.sourceText, typePosition, operandType, _
                       isPointer, -1, parser.context) <> 0 Then
                    parser.position = typePosition
                Else
                    If ParseSimpleUnaryValue( _
                        parser, operand, depth + 1, callableNames(), _
                        callableCount, parameterNames(), parameterAliases(), _
                        parameterTypes(), parameterCount) = 0 Then Return 0
                    operandType = operand.typeName
                End If
            End If
            parser.unevaluated = oldUnevaluated
            parser.hasFunctionCall = oldHasCall
            parser.hasBooleanOperator = oldHasBoolean
            ' SIZEOF deletes the operand AST in parser-quirk-math.bas. Emit a
            ' type query so an unevaluated C call needs no FreeBASIC body.
            ' Aggregate sizes require an explicitly matched layout.
            If operand.arrayBound <> "" Then
                Dim elementRecord As String = CBodyRecordName(parser.translation[0], parser.catalog[0], operand.arrayElementType)
                If operand.arrayBound = SIMPLE_UNKNOWN_ARRAY_BOUND OrElse _
                   (SimpleArithmeticKind(parser.catalog[0], operand.arrayElementType) = 0 AndAlso _
                    InStr(operand.arrayElementType, " Ptr") = 0 AndAlso _
                    IsCBodyCallbackTypeInContext(parser.translation[0], operand.arrayElementType) = 0 AndAlso _
                    CBodyRecordSizeIsKnown(parser.translation[0], parser.catalog[0], elementRecord) = 0) Then Return 0
                value.text = "Cast(c2fb_size_t, (" & operand.arrayBound & " * SizeOf(" & operand.arrayElementType & ")))"
            ElseIf operand.arrayCount > 0 Then
                value.text = "Cast(c2fb_size_t, " & Trim(Str(operand.arrayCount)) & "ULL)"
            Else
                If operand.isFunctionDesignator <> 0 Then Return 0
                Dim sourceRecord As String = CBodyRecordName(parser.translation[0], parser.catalog[0], operandType)
                If SimpleArithmeticKind(parser.catalog[0], operandType) = 0 AndAlso _
                   InStr(operandType, " Ptr") = 0 AndAlso _
                   IsCBodyCallbackTypeInContext(parser.translation[0], operandType) = 0 AndAlso _
                   CBodyRecordSizeIsKnown( _
                       parser.translation[0], parser.catalog[0], sourceRecord) = 0 Then
                    Dim genericRecordSize As Long = 0
                    If parser.translation[0].target.profile = C2FB_TARGET_GENERIC Then
                        If operand.isArrayElementZero <> 0 AndAlso _
                           operand.arraySourceName <> "" Then
                            Dim arrayObjectIndex As Long = _
                                CBodyExternalObjectIndex( _
                                    parser.translation[0], _
                                    operand.arraySourceName)
                            If arrayObjectIndex >= 0 Then
                                With parser.translation[0].body.externalObjects( _
                                    arrayObjectIndex)
                                    If .isArray <> 0 AndAlso _
                                       .isUnsizedArray = 0 AndAlso _
                                       .arrayRank = 1 Then
                                        GenericModuleStaticArrayElementSizeInContext( _
                                            parser.translation[0], _
                                            operand.arraySourceName, _
                                            genericRecordSize)
                                    End If
                                End With
                            End If
                        End If
                    End If
                    If genericRecordSize <= 0 Then _
                        genericRecordSize = GenericHeaderSimpleRecordSizeInBytes( _
                            parser.translation[0], operandType)
                    If genericRecordSize <= 0 Then
                        If parser.context <> 0 Then _
                            RecordSimpleBodyFailure( _
                                parser.context[0], "unknown-sizeof-record-layout", _
                                "could not verify the FreeBASIC size of C record type " & _
                                operandType & " (C source record " & sourceRecord & ")")
                        Return 0
                    End If
                    value.text = "Cast(c2fb_size_t, " & _
                        Trim(Str(genericRecordSize)) & "ULL)"
                Else
                    value.text = "Cast(c2fb_size_t, SizeOf(" & operandType & "))"
                End If
            End If
            If operand.arrayCount > 0 AndAlso operand.arraySourceName <> "" Then
                value.sizeOfArraySourceName = operand.arraySourceName
                value.sizeOfArrayCount = operand.arrayCount
            ElseIf operand.isArrayElementZero <> 0 AndAlso _
                   operand.arraySourceName <> "" Then
                value.sizeOfArrayElementSourceName = operand.arraySourceName
            End If
            value.typeName = "c2fb_size_t"
            value.isLValue = 0
            Return -1
        End If
        If identifier = "__builtin_va_arg" Then
            If ParseSimpleVaArgValue( _
                parser, value, depth, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
        ElseIf identifier = "_Generic" Then
            If ParseSimpleGenericSelectionValue( _
                parser, value, depth, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                parameterCount) = 0 Then Return 0
        ElseIf Mid(parser.sourceText, parser.position, 1) = "(" Then
            Dim mappedName As String = ParameterAlias(parameterNames(), parameterAliases(), parameterCount, identifier)
            If mappedName <> "" Then
                For i As Long = parameterCount - 1 To 0 Step -1
                    If parameterNames(i) = identifier Then
                        value.typeName = parameterTypes(i)
                        Exit For
                    End If
                Next
                If IsCBodyCallbackTypeInContext(parser.translation[0], value.typeName) = 0 Then Return 0
                value.text = mappedName
            Else
                Dim externalObjectIndex As Long = _
                    CBodyExternalObjectIndex(parser.translation[0], identifier)
                If externalObjectIndex >= 0 AndAlso _
                   IsCBodyCallbackTypeInContext( _
                       parser.translation[0], _
                       parser.translation[0].body.externalObjects(externalObjectIndex).freeBasicType) <> 0 Then
                    ' A file-scope C function pointer is callable just like a
                    ' callback parameter. Preserve its declared signature so
                    ' argument and result types follow the same path.
                    With parser.translation[0].body.externalObjects(externalObjectIndex)
                        value.text = .freeBasicName
                        value.typeName = .freeBasicType
                        value.layoutType = .freeBasicType
                        value.storageType = .freeBasicType
                        value.isLValue = -1
                    End With
                Else
                    Dim isExplainTextCall As Long = CInt(identifier = "sqlite3VdbeExplain")
                    Dim isVaStart As Long = CInt( _
                        identifier = "__builtin_va_start" OrElse _
                        identifier = "__builtin_c23_va_start")
                    Dim isVaEnd As Long = CInt(identifier = "__builtin_va_end")
                    Dim isVaCopy As Long = CInt(identifier = "__builtin_va_copy")
                    Dim isAtomicLoad As Long = CInt( _
                        identifier = "__atomic_load_n" AndAlso _
                        (parser.translation[0].body.assumeSingleThreadedAtomics <> 0 OrElse _
                         parser.translation[0].body.atomicMutexRuntime <> 0))
                    Dim isAtomicStore As Long = CInt( _
                        identifier = "__atomic_store_n" AndAlso _
                        (parser.translation[0].body.assumeSingleThreadedAtomics <> 0 OrElse _
                         parser.translation[0].body.atomicMutexRuntime <> 0))
                    Dim isAtomicExchange As Long = CInt( _
                        identifier = "__atomic_exchange_n" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isAtomicFetchAdd As Long = CInt( _
                        identifier = "__atomic_fetch_add" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isAtomicFetchSub As Long = CInt( _
                        identifier = "__atomic_fetch_sub" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isAtomicFetchOr As Long = CInt( _
                        identifier = "__atomic_fetch_or" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isAtomicFetchAnd As Long = CInt( _
                        identifier = "__atomic_fetch_and" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isAtomicFetchXor As Long = CInt( _
                        identifier = "__atomic_fetch_xor" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isAtomicCompareExchange As Long = CInt( _
                        identifier = "__atomic_compare_exchange_n" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isAtomicThreadFence As Long = CInt( _
                        identifier = "__atomic_thread_fence" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isAtomicIsLockFree As Long = CInt( _
                        identifier = "__atomic_is_lock_free" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isAtomicTestAndSet As Long = CInt( _
                        identifier = "__atomic_test_and_set" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isAtomicClear As Long = CInt( _
                        identifier = "__atomic_clear" AndAlso _
                        parser.translation[0].body.atomicMutexRuntime <> 0)
                    Dim isFiniteBuiltin As Long = _
                        CBodyFiniteTestBuiltin(identifier)
                    Dim isNaNBuiltin As Long = _
                        CBodyNaNTestBuiltin(identifier)
                    Dim isInfinitySignBuiltin As Long = _
                        CBodyInfinitySignTestBuiltin(identifier)
                    Dim builtinNaNType As String = _
                        CBodyBuiltinNaNType(identifier)
                    Dim builtinExpectKind As Long = _
                        CBodyBuiltinExpectKind(identifier)
                    Dim builtinConstantPKind As Long = _
                        CBodyBuiltinConstantP(identifier)
                    Dim builtinCpuSupports As Long = _
                        CBodyBuiltinCpuSupports(identifier)
                    Dim builtinStdBitCountKind As Long = _
                        CBodyBuiltinStdBitCountKind(identifier)
                    Dim builtinStdRotateKind As Long = _
                        CBodyBuiltinStdRotateKind(identifier)
                    Dim checkedOverflowPredicateKind As Long = _
                        CBodyBuiltinCheckedOverflowPredicateKind(identifier)
                    Dim isBuiltinCall As Long = CInt( _
                        CBodyBuiltinType(identifier) <> "" OrElse _
                        CBodyBuiltinCallTarget(identifier) <> "" OrElse _
                        CBodyBuiltinInfinityType(identifier) <> "" OrElse _
                        builtinNaNType <> "" OrElse _
                        CBodyBuiltinCheckedOverflowKind(identifier) <> 0 OrElse _
                        checkedOverflowPredicateKind <> 0 OrElse _
                        builtinExpectKind <> 0 OrElse _
                        builtinConstantPKind <> 0 OrElse _
                        builtinCpuSupports <> 0 OrElse _
                        builtinStdRotateKind <> 0 OrElse _
                        builtinStdBitCountKind <> 0 OrElse _
                        isVaStart <> 0 OrElse isVaEnd <> 0 OrElse _
                        isVaCopy <> 0 OrElse _
                        identifier = "__builtin_alloca" OrElse _
                        isFiniteBuiltin <> 0 OrElse _
                        isNaNBuiltin <> 0 OrElse _
                        isInfinitySignBuiltin <> 0 OrElse _
                        isAtomicLoad <> 0 OrElse isAtomicStore <> 0 OrElse _
                        isAtomicExchange <> 0 OrElse _
                        isAtomicFetchAdd <> 0 OrElse _
                        isAtomicFetchSub <> 0 OrElse _
                        isAtomicFetchOr <> 0 OrElse _
                        isAtomicFetchAnd <> 0 OrElse _
                        isAtomicFetchXor <> 0 OrElse _
                        isAtomicCompareExchange <> 0 OrElse _
                        isAtomicThreadFence <> 0 OrElse _
                        isAtomicIsLockFree <> 0 OrElse _
                        isAtomicTestAndSet <> 0 OrElse isAtomicClear <> 0)
                    Dim isSourceDeclaredProcedure As Long = CInt( _
                        CBodyProcedureIndex(parser.translation[0], identifier) >= 0)
                    If C2fbNameListContains(callableNames(), callableCount, identifier) = 0 AndAlso _
                       isSourceDeclaredProcedure = 0 AndAlso _
                       isExplainTextCall = 0 AndAlso _
                       isBuiltinCall = 0 AndAlso _
                       (parser.unevaluated = 0 OrElse _
                        CBodyReturnType( _
                            parser.translation[0], parser.catalog[0], identifier) = "") Then Return 0
                    If isExplainTextCall <> 0 Then
                        ' Fixed-signature adapters format the supported C varargs
                        ' forms without depending on a backend-specific va_list.
                        value.text = CBodyCallName( _
                            parser.translation[0], parser.catalog[0], identifier)
                    Else
                        value.text = CBodyCallName( _
                            parser.translation[0], parser.catalog[0], identifier)
                    End If
                    If isVaStart <> 0 OrElse isVaEnd <> 0 OrElse _
                       isVaCopy <> 0 Then
                        value.typeName = "void"
                    ElseIf builtinExpectKind <> 0 Then
                        value.typeName = "c2fb_c_long"
                    ElseIf builtinConstantPKind <> 0 Then
                        value.typeName = "c2fb_c_int"
                    Else
                        value.typeName = CBodyReturnType( _
                            parser.translation[0], parser.catalog[0], identifier)
                    End If
                End If
            End If
            If ParseSimpleCallValue(parser, value, identifier, depth, callableNames(), callableCount, _
                                    parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
        Else
            If TranslateSQLiteBodyIdentifier( _
                parser, value, identifier) = 0 Then
                value.text = ParameterAlias(parameterNames(), parameterAliases(), parameterCount, identifier)
                If Len(value.text) = 0 Then
                    Dim genericEnumIndex As Long = -1
                    If parser.translation[0].target.profile = C2FB_TARGET_GENERIC Then _
                        genericEnumIndex = GenericEnumMemberIndexInContext( _
                            parser.translation[0], identifier)
                    If genericEnumIndex >= 0 Then
                        With parser.translation[0].genericC.header.enumMembers( _
                            genericEnumIndex)
                            If .integerValueKnown <> 0 Then
                                value.text = Trim(Str(.integerValue))
                            ElseIf .isEmitted <> 0 AndAlso .freeBasicName <> "" Then
                                value.text = .freeBasicName
                            Else
                                Return 0
                            End If
                            value.typeName = "c2fb_c_int"
                            value.layoutType = value.typeName
                            value.storageType = value.typeName
                            value.isLValue = 0
                        End With
                    Else
                        Dim externalObjectIndex As Long = _
                            CBodyExternalObjectIndex(parser.translation[0], identifier)
                        If externalObjectIndex >= 0 Then
                            With parser.translation[0].body.externalObjects(externalObjectIndex)
                                value.cRecord = CBodyRecordName( _
                                    parser.translation[0], parser.catalog[0], .freeBasicType)
                                value.storageType = .freeBasicType
                                value.arrayCount = .arrayCount
                                value.isReadOnly = .isConst
                                value.pointerCount = .pointerCount
                                value.volatileMask = .volatileMask
                                If .isArray <> 0 Then
                                    value.text = .freeBasicName
                                    value.typeName = .freeBasicType & " Ptr"
                                    value.layoutType = value.typeName
                                    If .volatileMask <> 0 Then _
                                        value.pointerCount = .pointerCount + 1
                                    value.arrayElementType = .freeBasicType
                                    If .isUnsizedArray <> 0 Then
                                        value.arrayBound = SIMPLE_UNKNOWN_ARRAY_BOUND
                                    Else
                                        value.arrayBound = Trim(Str(.arrayCount)) & "ULL"
                                    End If
                                    value.arrayRank = .arrayRank
                                    If value.arrayRank <= 0 Then value.arrayRank = 1
                                    value.arrayDimensions = .arrayDimensions
                                    If value.arrayDimensions = "" Then _
                                        value.arrayDimensions = value.arrayBound
                                    value.arraySourceName = .sourceName
                                    value.isLayoutArray = -1
                                    value.isLValue = 0
                                Else
                                    value.text = .freeBasicName
                                    value.typeName = .freeBasicType
                                    value.layoutType = .freeBasicType
                                    value.isLValue = -1
                                    value.lValueText = value.text
                                End If
                            End With
                        Else
                            Dim reusedArrayType As String
                            Dim reusedArrayCount As Long
                            Dim reusedArrayName As String = _
                                GenericStaticObjectReuseInPolicy( _
                                    parser.translation[0].genericC.policy, _
                                    identifier)
                            If reusedArrayName <> "" AndAlso _
                               GenericStaticObjectLayoutInPolicy( _
                                   parser.translation[0].genericC.policy, _
                                   identifier, reusedArrayType, _
                                   reusedArrayCount) <> 0 Then
                                If Left(reusedArrayType, 6) = "Const " Then _
                                    reusedArrayType = Mid(reusedArrayType, 7)
                                value.text = reusedArrayName
                                value.typeName = reusedArrayType & " Ptr"
                                value.layoutType = value.typeName
                                value.storageType = reusedArrayType
                                value.arrayCount = reusedArrayCount
                                value.arrayBound = _
                                    Trim(Str(reusedArrayCount)) & "ULL"
                                value.arrayDimensions = value.arrayBound
                                value.arrayRank = 1
                                value.arrayElementType = reusedArrayType
                                value.arraySourceName = identifier
                                value.cRecord = CBodyRecordName( _
                                    parser.translation[0], parser.catalog[0], _
                                    reusedArrayType)
                                value.pointerCount = _
                                    SimpleTypePointerDepth(value.typeName)
                                value.isLayoutArray = -1
                                value.isLValue = 0
                            End If
                        End If
                        If value.text = "" Then
                            If C2fbNameListContains(callableNames(), callableCount, identifier) <> 0 OrElse _
                               CBodyProcedureIndex( _
                                   parser.translation[0], identifier) >= 0 Then
                                value.text = "ProcPtr(" & CBodyCallName( _
                                    parser.translation[0], parser.catalog[0], identifier) & ")"
                                value.typeName = "Any Ptr"
                                value.lValueText = identifier
                                value.isFunctionDesignator = -1
                            Else
                                If IsSQLiteConstantIdentifierInContext( _
                                    parser.translation[0], identifier) = 0 Then Return 0
                                value.text = identifier
                            End If
                        End If
                    End If
                Else
                    Dim parameterPosition As Long = -1
                    For symbolIndex As Long = parameterCount - 1 To 0 Step -1
                        If parameterNames(symbolIndex) = identifier Then
                            parameterPosition = symbolIndex
                            value.typeName = parameterTypes(symbolIndex)
                            Dim arrayMarker As Long = InStr(value.typeName, "[]")
                            If arrayMarker > 0 Then
                                value.arrayElementType = Left(value.typeName, arrayMarker - 1)
                                Dim arrayMetadata As String = _
                                    Mid(value.typeName, arrayMarker + 2)
                                Dim dimensionsSeparator As Long = _
                                    InStr(arrayMetadata, "|")
                                If dimensionsSeparator > 0 Then
                                    value.arrayBound = Left( _
                                        arrayMetadata, dimensionsSeparator - 1)
                                    value.arrayDimensions = Mid( _
                                        arrayMetadata, dimensionsSeparator + 1)
                                Else
                                    value.arrayBound = arrayMetadata
                                    value.arrayDimensions = arrayMetadata
                                End If
                                Dim alignmentMarker As Long = _
                                    InStr(value.arrayDimensions, "|")
                                If alignmentMarker > 0 Then
                                    Dim alignmentMetadata As String = _
                                        Mid(value.arrayDimensions, _
                                            alignmentMarker + 1)
                                    If Left(alignmentMetadata, 8) <> "aligned:" OrElse _
                                       EvaluateSimpleArrayBound( _
                                           Mid(alignmentMetadata, 9), _
                                           value.arrayCount, _
                                           MAX_GENERIC_ARRAY_COUNT) = 0 Then _
                                        Return 0
                                    value.arrayDimensions = Left( _
                                        value.arrayDimensions, alignmentMarker - 1)
                                    value.isAlignedArray = -1
                                End If
                                Dim dimensionParts() As String
                                If SplitSimpleCList( _
                                    value.arrayDimensions, dimensionParts(), _
                                    value.arrayRank) = 0 OrElse _
                                   value.arrayRank <= 0 Then Return 0
                                value.typeName = value.arrayElementType & " Ptr"
                                value.layoutType = value.typeName
                                value.isLayoutArray = -1
                            End If
                            Exit For
                        End If
                    Next
                    If parser.context <> 0 Then
                        Dim pointerArrayParameterIndex As Long = _
                            CBodyPointerToArrayParameterIndexByPositionInContext( _
                                parser.translation[0], _
                                parser.context->functionName, parameterPosition)
                        If pointerArrayParameterIndex >= 0 Then
                            With parser.translation[0].body.pointerToArrayParameters( _
                                pointerArrayParameterIndex)
                                value.typeName = .arrayElementType & " Ptr"
                                value.layoutType = value.typeName
                                value.storageType = value.typeName
                                value.isPointerToArray = -1
                                value.pointerToArrayElementCount = _
                                    .arrayElementCount
                                value.isReadOnly = .isConst
                            End With
                        End If
                    End If
                    value.isLValue = -1
                    value.storageType = value.typeName
                    If parser.context <> 0 Then
                        value.isReadOnly = (InStr(parser.context->readOnlyAliases, "|" & value.text & "|") <> 0)
                    End If
                End If
            End If
        End If
    Else
        Return 0
    End If

    If value.isLValue <> 0 Then
        Dim localVolatilePointerCount As Long
        Dim localVolatileMask As Long
        If parser.context <> 0 AndAlso _
           LookupSimpleBodyVolatileLocal( _
               parser.context[0], value.text, localVolatilePointerCount, _
               localVolatileMask) <> 0 Then
            value.pointerCount = localVolatilePointerCount
            value.volatileMask = localVolatileMask
            If localVolatileMask <> 0 Then value.lValueText = value.text
        ElseIf value.pointerCount = 0 Then
            value.pointerCount = SimpleTypePointerDepth(value.typeName)
        End If
    End If

    If value.layoutType = "" Then value.layoutType = value.typeName
    If value.pointerCount = 0 Then _
        value.pointerCount = SimpleTypePointerDepth(value.typeName)
    If value.cRecord = "" Then value.cRecord = CBodyRecordName(parser.translation[0], parser.catalog[0], value.typeName)
    If parser.unevaluated = 0 AndAlso _
       (value.isLValue <> 0 OrElse value.isFunctionDesignator <> 0) Then _
        parser.hasRuntimeValue = -1
    Do
        SkipCSpaces(parser.sourceText, parser.position)
        Dim suffix As String = Mid(parser.sourceText, parser.position, 2)
        If suffix = "->" OrElse Left(suffix, 1) = "." Then
            If suffix = "->" AndAlso value.isLayoutArray <> 0 Then
                ' C decays an array member before applying pointer-member access.
                If InStr(value.typeName, " Ptr") = 0 Then Return 0
                value.text = "CPtr(" & value.typeName & ", @(" & _
                    value.text & "(0)))"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.isLayoutArray = 0
                If value.volatileMask <> 0 Then value.pointerCount += 1
                value.arrayCount = 0
                value.arrayRank = 0
                value.arrayBound = ""
                value.arrayDimensions = ""
                value.arrayElementType = ""
                value.arraySourceName = ""
                value.isLValue = 0
                value.lValueText = ""
            End If
            Dim ownerVolatileBase As Long = _
                CInt((value.volatileMask And 1) <> 0)
            If suffix = "->" AndAlso _
               SimpleValueHasVolatilePointerAccess(value) <> 0 AndAlso _
               value.volatileReadLowered = 0 Then
                Dim volatilePointerRead As String
                If BuildCBodyVolatilePointerLoad( _
                    parser, value, value.lValueText, _
                    volatilePointerRead) = 0 Then Return 0
                value.text = volatilePointerRead
                value.volatileReadLowered = -1
                value.isWholeCall = -1
                parser.hasFunctionCall = -1
            End If
            Dim memberOwnerText As String = value.text
            Dim owner As String = value.layoutType
            If suffix = "->" Then
                If SimplePointeeType(value.typeName) = "Any" Then Return 0
                value.isReadOnly = (Left(value.typeName, 6) = "Const ")
                parser.position += 2
                owner = SimplePointeeType(owner)
            Else
                suffix = "."
                parser.position += 1
                If value.cRecord = "sqlite3.u1" AndAlso _
                   Right(value.typeName, 4) = " Ptr" Then
                    ' SQLite stores the C u1 union inline, while the port
                    ' exposes its interrupt flag directly on sqlite3.
                    suffix = "->"
                    owner = SimplePointeeType(owner)
                ElseIf value.cRecord = "sqlite3_kvvfs_methods" Then
                    suffix = "->"
                    owner = SimplePointeeType(owner)
                End If
            End If
            SkipCSpaces(parser.sourceText, parser.position)
            If parser.position > Len(parser.sourceText) OrElse _
               IsIdentifierStart(Asc(parser.sourceText, parser.position)) = 0 Then Return 0
            Dim start As Long = parser.position
            parser.position += 1
            While parser.position <= Len(parser.sourceText) AndAlso _
                  IsIdentifierPart(Asc(parser.sourceText, parser.position)) <> 0
                parser.position += 1
            Wend
            Dim fieldName As String = Mid(parser.sourceText, start, parser.position - start)
            Dim memberOwnerIsPointer As Long = CInt(suffix = "->")
            Dim flattenedSqliteInterruptUnion As Long = CInt( _
                parser.translation[0].target.profile = C2FB_TARGET_SQLITE AndAlso _
                value.cRecord = "sqlite3.u1")
            Dim cField As Long = CBodyRecordFieldIndex( _
                parser.translation[0], parser.catalog[0], value.cRecord, fieldName)
            If parser.translation[0].target.profile = C2FB_TARGET_SQLITE AndAlso _
               value.cRecord = "unixFileId" AndAlso _
               (Right(memberOwnerText, 8) = "->fileId" OrElse _
                Right(memberOwnerText, 7) = ".fileId") Then
                Dim flattenedFieldName As String
                Select Case fieldName
                Case "dev": flattenedFieldName = "devId"
                Case "ino": flattenedFieldName = "fileId"
                Case Else: Return 0
                End Select
                Dim flattenedFieldIndex As Long = LookupFbBodyField( _
                    parser.translation[0], parser.catalog[0], _
                    "UnixLockInfo", flattenedFieldName)
                If cField < 0 OrElse flattenedFieldIndex < 0 Then Return 0

                ' UnixLockInfo stores C's leading unixFileId.dev/ino pair as
                ' the adjacent devId and fileId scalars. The C member path is
                ' already positioned at fileId when this nested access lands.
                value.text = memberOwnerText
                If fieldName = "dev" Then
                    If Right(value.text, Len("fileId")) <> "fileId" Then Return 0
                    value.text = Left( _
                        value.text, Len(value.text) - Len("fileId")) & _
                        flattenedFieldName
                End If
                value.lValueText = value.text
                value.typeName = NormalizeFbBodyType( _
                    parser.catalog[0], _
                    parser.catalog[0].bodyFields(flattenedFieldIndex).typeName)
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.cRecord = ""
                value.isLValue = -1
                value.isLayoutArray = 0
                value.arrayCount = 0
                value.arrayRank = 0
                value.arrayBound = ""
                value.arrayDimensions = ""
                value.arrayElementType = ""
                value.arraySourceName = ""
                value.isFunctionDesignator = 0
                value.isWholeCall = 0
                Continue Do
            End If
            Dim fbFieldIndex As Long
            If flattenedSqliteInterruptUnion <> 0 Then
                fbFieldIndex = LookupFbBodyField( _
                    parser.translation[0], parser.catalog[0], owner, fieldName)
                If cField >= 0 AndAlso fbFieldIndex < 0 Then Return 0
            End If
            If parser.translation[0].target.profile = C2FB_TARGET_SQLITE AndAlso _
               owner = "sqlite3" AndAlso fieldName = "u1" AndAlso _
               cField >= 0 AndAlso _
               parser.translation[0].body.recordFields(cField).sourceType = _
                   "sqlite3.u1" AndAlso _
               CBodyRecordFieldIndex( _
                   parser.translation[0], parser.catalog[0], _
                   "sqlite3.u1", "isInterrupted") >= 0 AndAlso _
               LookupFbBodyField( _
                   parser.translation[0], parser.catalog[0], _
                   "sqlite3", "isInterrupted") >= 0 Then
                ' The source exposes u1 as a named union, but SQLite's
                ' FreeBASIC connection layout stores isInterrupted directly.
                ' Preserve the union's C field index for the next member read.
                value.text = memberOwnerText
                value.lValueText = memberOwnerText
                value.typeName = IIf( _
                    value.isReadOnly <> 0, "Const ", "") & "sqlite3" & _
                    IIf(memberOwnerIsPointer <> 0, " Ptr", "")
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.cRecord = "sqlite3.u1"
                value.isLValue = -1
                value.isLayoutArray = 0
                value.arrayCount = 0
                value.arrayBound = ""
                value.isFunctionDesignator = 0
                value.isWholeCall = 0
                Continue Do
            End If
            If suffix = "." AndAlso owner = "SqliteFuncDefUnion" AndAlso _
               value.cRecord = "FuncDef.u" AndAlso _
               NormalizeFbBodyType(parser.catalog[0], value.storageType) = "Any Ptr" Then
                Dim unionField As Long = CBodyRecordFieldIndex(parser.translation[0], parser.catalog[0], "FuncDef.u", fieldName)
                If unionField < 0 Then Return 0
                Dim unionStorage As String = value.text
                Dim unionStorageLValue As String = value.lValueText
                Dim unionMemberType As String = CBodyFieldType(parser.translation[0], parser.catalog[0], unionField)
                If fieldName = "pHash" Then
                    value.text = "CPtr(" & unionMemberType & ", " & unionStorage & ")"
                Else
                    value.text = unionStorage
                End If
                value.lValueText = unionStorageLValue
                value.typeName = unionMemberType
                value.layoutType = unionMemberType
                value.storageType = "Any Ptr"
                value.cRecord = parser.translation[0].body.recordFields(unionField).sourceType
                value.isLayoutArray = 0
                value.arrayCount = 0
                value.arrayBound = ""
                value.isLValue = -1
                value.isFunctionDesignator = 0
                value.isWholeCall = 0
                Continue Do
            End If
            If suffix = "." AndAlso owner = "SqliteGlobalBuiltinFunctions" Then
                If fieldName <> "a" Then Return 0
                value.text = "sqlite3BuiltinFunctionBucketsPtr()"
                value.typeName = "SqliteFuncDef Ptr Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.cRecord = ""
                value.isLValue = 0
                value.lValueText = ""
                value.isWholeCall = -1
                value.isFunctionDesignator = 0
                value.arrayCount = 0
                value.arrayBound = ""
                parser.hasFunctionCall = -1
                Continue Do
            End If
            If suffix = "." AndAlso owner = "SqliteGlobalConfig" Then
                Dim configFieldType As String
                Dim configFieldText As String = _
                    SQLiteConfigFieldExpression(fieldName, configFieldType)
                If configFieldText = "" Then Return 0
                value.text = configFieldText
                value.typeName = configFieldType
                value.layoutType = configFieldType
                value.storageType = configFieldType
                If fieldName = "pcache2" Then
                    value.cRecord = "sqlite3_pcache_methods2"
                    ' The port stores this copied callback table separately.
                    ' A snapshot supports C reads while keeping writes on the
                    ' dedicated sqlite3ConfigSetPcacheMethods path.
                    value.isReadOnly = -1
                Else
                    value.cRecord = ""
                End If
                value.isLValue = 0
                value.lValueText = ""
                value.isWholeCall = -1
                value.isFunctionDesignator = 0
                value.arrayCount = 0
                value.arrayBound = ""
                parser.hasFunctionCall = -1
                Continue Do
            End If
            Dim fbFieldName As String = CBodyFreeBasicFieldNameForAccess( _
                parser.translation[0], owner, fieldName, cField)
            value.text &= suffix & fbFieldName
            value.lValueText = value.text
            value.typeName = ""
            value.layoutType = ""
            value.isLayoutArray = 0
            Dim fieldIndex As Long = fbFieldIndex
            If flattenedSqliteInterruptUnion = 0 Then _
                fieldIndex = LookupFbBodyField( _
                    parser.translation[0], parser.catalog[0], owner, fieldName, cField)
            If cField >= 0 AndAlso fieldIndex < 0 Then
                Dim tailAccessorName As String = _
                    CBodyGenericFlexibleArrayAccessorName( _
                        parser.translation[0], parser.catalog[0], cField)
                If tailAccessorName <> "" Then
                    If memberOwnerIsPointer = 0 AndAlso value.isLValue = 0 Then _
                        Return 0
                    Dim recordPointer As String = memberOwnerText
                    If memberOwnerIsPointer = 0 Then _
                        recordPointer = "@(" & memberOwnerText & ")"
                    value.text = "(" & tailAccessorName & "(" & _
                        recordPointer & "))"
                    value.lValueText = ""
                    value.typeName = CBodyFieldType( _
                        parser.translation[0], parser.catalog[0], cField)
                    If value.typeName = "" Then Return 0
                    value.layoutType = value.typeName
                    value.storageType = value.typeName
                    value.arrayElementType = SimplePointeeType(value.typeName)
                    value.arrayCount = 0
                    value.arrayRank = 0
                    value.arrayBound = SIMPLE_UNKNOWN_ARRAY_BOUND
                    value.arrayDimensions = ""
                    value.arraySourceName = ""
                    value.isArrayElementZero = 0
                    value.isIncompleteArray = -1
                    value.cRecord = ""
                    value.isLValue = 0
                    value.isLayoutArray = 0
                    value.isFunctionDesignator = 0
                    value.isWholeCall = 0
                    If parser.translation[0].body.recordFields(cField).isConst <> 0 Then _
                        value.isReadOnly = -1
                    Continue Do
                End If
            End If
            If cField >= 0 AndAlso fieldIndex < 0 Then
                Dim mappedBitStorage As String = _
                    MappedFbBitFieldStorageField( _
                        parser.translation[0], owner, fieldName)
                If parser.translation[0].body.recordFields(cField).bitWidth < 0 OrElse _
                   mappedBitStorage = "" OrElse _
                   LookupFbBodyField( _
                       parser.translation[0], parser.catalog[0], _
                       owner, mappedBitStorage) < 0 Then
                    If parser.context <> 0 Then _
                        RecordSimpleBodyFailure( _
                            parser.context[0], "unmapped-record-field", _
                            "no FreeBASIC storage field for C member " & _
                            owner & "." & fieldName)
                    Return 0
                End If
            ElseIf cField < 0 AndAlso fieldIndex < 0 Then
                If parser.context <> 0 Then _
                    RecordSimpleBodyFailure( _
                        parser.context[0], "unmapped-record-field", _
                        "no complete C or FreeBASIC record layout for member " & _
                        owner & "." & fieldName)
                Return 0
            End If
            If fieldIndex >= 0 Then
                value.layoutType = parser.catalog[0].bodyFields(fieldIndex).typeName
                value.isLayoutArray = parser.catalog[0].bodyFields(fieldIndex).isArray
                If value.isLayoutArray <> 0 Then value.layoutType &= " Ptr"
            End If
            value.storageType = value.layoutType
            value.cRecord = ""
            If cField < 0 AndAlso fieldIndex >= 0 Then
                ' A private anonymous C record may be declared in a separate
                ' type-context pass, where its C field table is unavailable.
                ' The generated FreeBASIC field still supplies the storage
                ' type needed for ordinary reads and writes.
                value.typeName = NormalizeFbBodyType( _
                    parser.catalog[0], _
                    parser.catalog[0].bodyFields(fieldIndex).typeName)
                If parser.catalog[0].bodyFields(fieldIndex).isArray <> 0 Then _
                    value.typeName &= " Ptr"
                value.pointerCount = SimpleTypePointerDepth(value.typeName)
            End If
            Dim fieldIsWritable As Long = -1
            If cField >= 0 Then
                value.typeName = CBodyFieldType(parser.translation[0], parser.catalog[0], cField)
                value.cRecord = parser.translation[0].body.recordFields(cField).sourceType
                value.bitWidth = parser.translation[0].body.recordFields(cField).bitWidth
                value.pointerCount = parser.translation[0].body.recordFields(cField).pointerCount
                value.volatileMask = parser.translation[0].body.recordFields(cField).volatileMask
                If ownerVolatileBase <> 0 Then _
                    value.volatileMask = value.volatileMask Or _
                        (1 Shl value.pointerCount)
                If value.isLayoutArray <> 0 AndAlso value.volatileMask <> 0 Then _
                    value.pointerCount += 1
                If fieldIndex >= 0 AndAlso _
                   parser.translation[0].body.recordFields(cField).pointerCount > 0 AndAlso _
                   parser.catalog[0].bodyFields(fieldIndex).isArray <> 0 Then _
                    fieldIsWritable = 0
                If CBodyRecordName(parser.translation[0], parser.catalog[0], value.typeName) <> "" Then
                    ' A port field may store a C record pointer as Any Ptr.
                    ' Use its mapped C type for a following -> access while
                    ' keeping storageType tied to the actual FreeBASIC field.
                    value.layoutType = value.typeName
                End If
                ' C controls whether member access decays an array. The
                ' oversized-database Vdbe layout keeps these two masks as
                ' arrays, while the default C profile and FreeBASIC layout
                ' use scalar yDbMask values.
                If fieldIndex >= 0 AndAlso owner = "SqliteVdbe" AndAlso _
                   (fieldName = "lockMask" OrElse fieldName = "btreeMask") AndAlso _
                   parser.translation[0].body.recordFields(cField).isArray = 0 Then
                    value.isLayoutArray = 0
                    value.layoutType = parser.catalog[0].bodyFields(fieldIndex).typeName
                End If
                If value.bitWidth >= 0 Then
                    Dim bitfieldSignedness As Long = CBodyFieldBitFieldSignedness( _
                        parser.translation[0], parser.catalog[0], cField)
                    If bitfieldSignedness = C2FB_BITFIELD_SIGNEDNESS_UNKNOWN OrElse _
                       value.bitWidth > 32 Then Return 0
                    If bitfieldSignedness = C2FB_BITFIELD_SIGNEDNESS_UNSIGNED Then
                        value.isUnsignedBitField = -1
                    Else
                        value.isSignedBitField = -1
                    End If
                    value.bitOffset = parser.translation[0].body.recordFields(cField).bitOffset
                    If fieldIndex >= 0 AndAlso parser.catalog[0].bodyFields(fieldIndex).isArray = 0 Then
                        ' FreeBASIC's generated binding stores the bitfield as
                        ' a named field. Capture its containing record instead
                        ' of taking the address of the bitfield itself.
                        value.isDirectBitField = -1
                        value.bitFieldOwnerText = memberOwnerText
                        value.bitFieldOwnerType = owner
                        value.bitFieldName = fbFieldName
                        value.bitFieldOwnerIsPointer = memberOwnerIsPointer
                        If value.isSignedBitField <> 0 Then
                            value.text = SimpleBitFieldValueText( _
                                value.typeName, value.text, value.bitWidth, 0, _
                                bitfieldSignedness)
                            If value.text = "" Then Return 0
                        End If
                    Else
                        Dim storageFieldName As String = _
                            MappedFbBitFieldStorageField(parser.translation[0], owner, fieldName)
                        If storageFieldName = "" Then storageFieldName = "flags"
                        Dim storageIndex As Long = _
                            LookupFbBodyField(parser.translation[0], parser.catalog[0], owner, storageFieldName)
                        If storageIndex < 0 Then Return 0
                        If Right(value.text, Len(fieldName)) <> fieldName Then Return 0
                        Dim storageText As String = _
                            Left(value.text, Len(value.text) - Len(fieldName)) & storageFieldName
                        value.bitStorageText = storageText
                        value.storageType = NormalizeFbBodyType(parser.catalog[0],  _
                            parser.catalog[0].bodyFields(storageIndex).typeName)
                        value.isPackedBitField = -1
                        value.text = SimpleBitFieldValueText( _
                            value.typeName, storageText, value.bitWidth, _
                            value.bitOffset, bitfieldSignedness)
                        If value.text = "" Then Return 0
                    End If
                End If
                If fieldIndex >= 0 AndAlso value.isLayoutArray = 0 AndAlso value.typeName <> "" Then
                    If IsCBodyCallbackTypeInContext(parser.translation[0], value.typeName) <> 0 Then
                        value.text = "CPtr(" & value.typeName & ", " & value.text & ")"
                    ElseIf InStr(value.typeName, " Ptr") <> 0 Then
                        ' layoutType follows the C pointee for nested access.
                        ' storageType still records the actual port field, which
                        ' may be Any Ptr and needs a cast before dereferencing.
                        If NormalizeFbBodyType(parser.catalog[0], value.storageType) <> value.typeName Then _
                            value.text = "CPtr(" & value.typeName & ", " & value.text & ")"
                    ElseIf SimpleArithmeticKind(parser.catalog[0], value.typeName) > 0 AndAlso _
                           NormalizeFbBodyType(parser.catalog[0], value.layoutType) <> value.typeName Then
                        value.text = "Cast(" & value.typeName & ", " & value.text & ")"
                    End If
                End If
                If value.typeName <> "" Then value.layoutType = value.typeName
            End If
            value.isLValue = fieldIsWritable
            value.arrayCount = 0
            value.arrayBound = ""
            If cField >= 0 AndAlso parser.translation[0].body.recordFields(cField).isArray <> 0 Then
                ' C member arrays also retain their complete sizeof before
                ' decay. A missing or compound bound cannot establish a size.
                value.arrayBound = SIMPLE_UNKNOWN_ARRAY_BOUND
                value.arrayElementType = SimplePointeeType(value.typeName)
                Dim boundCount As Long
                If EvaluateSimpleArrayBound( _
                    parser.translation[0].body.recordFields(cField).arrayBound, _
                    boundCount, MAX_GENERIC_ARRAY_COUNT) <> 0 Then
                    value.arrayBound = Trim(Str(boundCount)) & "ULL"
                ElseIf parser.translation[0].target.profile = _
                       C2FB_TARGET_GENERIC AndAlso _
                       EvaluateGenericBodyArrayBound( _
                           parser.translation[0], _
                           parser.translation[0].body.recordFields(cField).arrayBound, _
                           boundCount, MAX_GENERIC_ARRAY_COUNT) <> 0 Then
                    ' C array bounds can retain sizeof typedefs after the
                    ' generic-header pass. Use its ABI-aware constant resolver
                    ' when the simple literal-bound parser cannot reduce them.
                    value.arrayBound = Trim(Str(boundCount)) & "ULL"
                ElseIf fieldIndex >= 0 AndAlso _
                       parser.catalog[0].bodyFields(fieldIndex).arrayCount > 0 Then
                    ' The C bound can depend on nested sizeof expressions in
                    ' macros. The generated FreeBASIC record retains the
                    ' resolved fixed extent for the same field.
                    value.arrayBound = Trim(Str( _
                        parser.catalog[0].bodyFields(fieldIndex).arrayCount)) & _
                        "ULL"
                End If
                If fieldIndex >= 0 AndAlso value.isLayoutArray = 0 Then _
                    value.isArrayStorageAlias = -1
            ElseIf fieldIndex >= 0 AndAlso _
                   parser.catalog[0].bodyFields(fieldIndex).isArray <> 0 AndAlso _
                   parser.catalog[0].bodyFields(fieldIndex).arrayCount > 0 Then
                value.arrayBound = Trim(Str( _
                    parser.catalog[0].bodyFields(fieldIndex).arrayCount)) & "ULL"
                value.arrayElementType = SimplePointeeType(value.typeName)
            End If
            value.isWholeCall = 0
        ElseIf Left(suffix, 1) = "[" Then
            Dim sourcePointerType As String = value.typeName
            Dim sourceStorageType As String = value.storageType
            Dim sourceArrayName As String = value.arraySourceName
            Dim sourceArrayIsReadOnly As Long = value.isReadOnly
            Dim sourceIsPointerToArray As Long = value.isPointerToArray
            Dim sourcePointerToArrayElementCount As Long = _
                value.pointerToArrayElementCount
            Dim sourcePointerDepth As Long = 0
            Dim sourcePointerBase As String = sourcePointerType
            While Right(sourcePointerBase, 4) = " Ptr"
                sourcePointerDepth += 1
                sourcePointerBase = Left(sourcePointerBase, Len(sourcePointerBase) - 4)
            Wend
            parser.position += 1
            Dim indexTextStart As Long = parser.position
            Dim indexValue As SimpleExpressionValue
            If ParseSimpleExpressionValue(parser, indexValue, 1, depth + 1, callableNames(), callableCount, _
                                          parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
            Dim indexText As String = Mid( _
                parser.sourceText, indexTextStart, parser.position - indexTextStart)
            value.prelude &= indexValue.prelude
            SkipCSpaces(parser.sourceText, parser.position)
            If Mid(parser.sourceText, parser.position, 1) <> "]" Then Return 0
            parser.position += 1
            If value.isLayoutArray <> 0 AndAlso value.arrayRank > 1 Then
                Dim dimensionBounds() As String
                Dim dimensionBoundCount As Long
                If SplitSimpleCList( _
                    value.arrayDimensions, dimensionBounds(), _
                    dimensionBoundCount) = 0 OrElse _
                   dimensionBoundCount <> value.arrayRank Then Return 0
                Dim indexExpressions() As String
                ReDim indexExpressions(0 To value.arrayRank - 1)
                indexExpressions(0) = indexValue.text
                Dim indexCount As Long = 1
                While indexCount < value.arrayRank
                    SkipCSpaces(parser.sourceText, parser.position)
                    If Mid(parser.sourceText, parser.position, 1) <> "[" Then Exit While
                    parser.position += 1
                    Dim nextIndexValue As SimpleExpressionValue
                    If ParseSimpleExpressionValue( _
                        parser, nextIndexValue, 1, depth + 1, callableNames(), _
                        callableCount, parameterNames(), parameterAliases(), _
                        parameterTypes(), parameterCount) = 0 Then Return 0
                    value.prelude &= nextIndexValue.prelude
                    SkipCSpaces(parser.sourceText, parser.position)
                    If Mid(parser.sourceText, parser.position, 1) <> "]" Then Return 0
                    parser.position += 1
                    indexExpressions(indexCount) = nextIndexValue.text
                    indexCount += 1
                Wend

                Dim flattenedIndex As String = indexExpressions(0)
                Dim indexedDimensions As String = indexExpressions(0)
                For dimensionIndex As Long = 1 To indexCount - 1
                    flattenedIndex = "(" & flattenedIndex & " * (" & _
                        dimensionBounds(dimensionIndex) & ") + (" & _
                        indexExpressions(dimensionIndex) & "))"
                    indexedDimensions &= ", " & indexExpressions(dimensionIndex)
                Next
                Dim remainingElementCount As String = "1ULL"
                Dim remainingDimensions As String
                For dimensionIndex As Long = indexCount To value.arrayRank - 1
                    remainingElementCount = "(" & remainingElementCount & _
                        " * (" & dimensionBounds(dimensionIndex) & "))"
                    If remainingDimensions <> "" Then _
                        remainingDimensions &= ","
                    remainingDimensions &= dimensionBounds(dimensionIndex)
                Next
                Dim arrayName As String = value.text
                Dim elementType As String = value.arrayElementType
                Dim usesMultidimensionalStorage As Long = 0
                If value.arraySourceName <> "" Then
                    Dim sourceArrayObjectIndex As Long = _
                        CBodyExternalObjectIndex( _
                            parser.translation[0], value.arraySourceName)
                    If sourceArrayObjectIndex >= 0 Then
                        ' Reused static arrays live in the type context with
                        ' their original rank. Body-owned and local arrays use
                        ' the row-major flat storage emitted by the body pass.
                        If parser.translation[0].body.externalObjects( _
                            sourceArrayObjectIndex).isReused <> 0 Then _
                            usesMultidimensionalStorage = -1
                    End If
                End If
                If indexCount < value.arrayRank AndAlso _
                   value.arrayRank - indexCount > 1 AndAlso _
                   parser.unevaluated = 0 Then Return 0
                If indexCount = value.arrayRank Then
                    If usesMultidimensionalStorage <> 0 Then
                        value.text = arrayName & "(" & indexedDimensions & ")"
                    Else
                        value.text = arrayName & "(" & flattenedIndex & ")"
                    End If
                    value.typeName = elementType
                    value.layoutType = elementType
                    value.storageType = elementType
                    value.cRecord = CBodyRecordName( _
                        parser.translation[0], parser.catalog[0], elementType)
                    value.isLValue = -1
                    value.lValueText = value.text
                    value.isReadOnly = sourceArrayIsReadOnly
                    value.arrayCount = 0
                    value.arrayRank = 0
                    value.arrayBound = ""
                    value.arrayDimensions = ""
                    value.arraySourceName = ""
                    value.isLayoutArray = 0
                    value.isArrayElementZero = 0
                Else
                    If usesMultidimensionalStorage <> 0 Then
                        ' Header-owned arrays retain their dimensions. Select
                        ' the first element of the remaining row for C decay.
                        For dimensionIndex As Long = indexCount To _
                            value.arrayRank - 1
                            indexedDimensions &= ", 0"
                        Next
                        value.text = "CPtr(" & elementType & " Ptr, @(" & _
                            arrayName & "(" & indexedDimensions & ")))"
                    Else
                        Dim baseOffset As String = _
                            "(" & flattenedIndex & " * " & _
                            remainingElementCount & ")"
                        value.text = "CPtr(" & elementType & " Ptr, @(" & _
                            arrayName & "(" & baseOffset & ")))"
                    End If
                    value.typeName = elementType & " Ptr"
                    value.layoutType = value.typeName
                    value.storageType = value.typeName
                    value.cRecord = CBodyRecordName( _
                        parser.translation[0], parser.catalog[0], elementType)
                    value.isLValue = 0
                    value.lValueText = ""
                    value.isReadOnly = sourceArrayIsReadOnly
                    value.arrayCount = 0
                    If parser.unevaluated <> 0 Then
                        value.arrayBound = remainingElementCount
                        value.arrayDimensions = remainingDimensions
                        value.arrayRank -= indexCount
                    Else
                        value.arrayRank = 0
                        value.arrayBound = ""
                        value.arrayDimensions = ""
                    End If
                    value.arraySourceName = ""
                    value.arrayElementType = elementType
                    value.isLayoutArray = 0
                    value.isArrayElementZero = 0
                End If
                value.isWholeCall = 0
                Continue Do
            End If
            If value.cRecord = "C2FB_CARRAY_TYPE_NAMES" Then
                value.text = "sqlite3CarrayTypeTable()[" & indexValue.text & "]"
                value.typeName = "Const ZString Ptr"
                value.layoutType = value.typeName
                value.storageType = value.typeName
                value.cRecord = ""
                value.isLValue = 0
                value.isReadOnly = -1
                value.lValueText = ""
                value.arrayElementType = ""
                value.arrayCount = 0
                value.arrayBound = ""
                value.isWholeCall = -1
                parser.hasFunctionCall = -1
            ElseIf value.isLayoutArray <> 0 AndAlso _
                   value.isAlignedArray <> 0 Then
                value.text &= "[" & indexValue.text & "]"
            ElseIf value.isLayoutArray <> 0 Then
                value.text &= "(" & indexValue.text & ")"
            ElseIf sourceIsPointerToArray <> 0 Then
                Dim elementPointerType As String = sourcePointerType
                If Right(elementPointerType, 4) <> " Ptr" OrElse _
                   sourcePointerToArrayElementCount <= 0 Then Return 0
                Dim typedArrayPointer As String = _
                    "CPtr(" & elementPointerType & ", " & _
                    SimpleCharacterPointer(value) & ")"
                Dim rowOffset As String = "(" & indexValue.text & " * " & _
                    Trim(Str(sourcePointerToArrayElementCount)) & ")"
                value.text = "CPtr(" & elementPointerType & ", @(" & _
                    typedArrayPointer & "[" & rowOffset & "]))"
            Else
                ' FreeBASIC uses [] for typed pointer indexing and () for
                ' declared array indexing. Keep C pointer subscripting typed.
                Dim pointerText As String = SimpleCharacterPointer(value)
                ' A known FreeBASIC field layout may retain the pointer type
                ' when the C field type is unavailable in the body model. In
                ' that case the field expression already has usable storage
                ' typing; never emit an empty CPtr type argument.
                If value.typeName <> "" AndAlso value.storageType <> "" AndAlso _
                   NormalizeFbBodyType( _
                       parser.catalog[0], value.storageType) <> value.typeName Then _
                    pointerText = "CPtr(" & value.typeName & ", " & pointerText & ")"
                value.text = pointerText & _
                             "[" & indexValue.text & "]"
            End If
            ' For a pointer-to-pointer, the leading Const qualifies the
            ' pointed-to character or record. It does not make the pointer
            ' stored in this array slot read-only. The declaration's own
            ' pointer-const qualifier is tracked separately on the alias.
            If sourcePointerDepth = 1 Then _
                value.isReadOnly = (Left(value.typeName, 6) = "Const ") OrElse value.isReadOnly
            value.isIncompleteArray = 0
            If sourceIsPointerToArray <> 0 Then
                ' The C subscript selects one array row, which then decays to a
                ' pointer to that row's first element in value context.
                value.typeName = sourcePointerType
                value.layoutType = sourcePointerType
                value.storageType = sourcePointerType
                value.cRecord = ""
                value.isLValue = 0
                value.lValueText = ""
                value.arrayCount = 0
                value.arrayBound = ""
                value.arrayRank = 0
                value.arrayDimensions = ""
                value.arrayElementType = ""
                value.isLayoutArray = 0
                value.isPointerToArray = 0
                value.pointerToArrayElementCount = 0
            Else
                Dim arrayElementType As String = _
                    SimplePointeeType(sourcePointerType)
                Dim arrayElementStorageType As String = _
                    SimpleArrayElementStorageType( _
                        sourceStorageType, sourcePointerType)
                If value.isLayoutArray <> 0 AndAlso _
                   value.arrayElementType <> "" Then
                    ' A declared C array already records its element type.
                    ' Its elements may be pointers, so peeling one level from
                    ' the array's decayed pointer would lose that pointer.
                    arrayElementType = value.arrayElementType
                    arrayElementStorageType = value.arrayElementType
                End If
                value.typeName = arrayElementType
                If value.typeName = "" AndAlso value.isLayoutArray <> 0 Then
                    ' A C array typedef can hide its scalar element type from the
                    ' body alias table while the generated layout still has the
                    ' exact FreeBASIC storage type for this indexed element.
                    value.typeName = SimplePointeeType(sourceStorageType)
                End If
                value.layoutType = SimplePointeeType(value.layoutType)
                value.cRecord = CBodyRecordName( _
                    parser.translation[0], parser.catalog[0], value.typeName)
                value.storageType = arrayElementStorageType
                value.isLayoutArray = 0
                value.isAlignedArray = 0
                If value.typeName = "Any" Then Return 0
                value.isLValue = -1
                value.lValueText = value.text
                value.arrayCount = 0
                value.arrayBound = ""
            End If
            value.arraySourceName = sourceArrayName
            value.isArrayElementZero = CInt( _
                sourceArrayName <> "" AndAlso IsSimpleZeroArrayIndex(indexText) <> 0)
            value.isWholeCall = 0
        ElseIf Left(suffix, 1) = "(" Then
            Dim directProcedureName As String = ""
            If value.isFunctionDesignator <> 0 Then
                directProcedureName = Trim(value.lValueText)
                ' The parenthesized-primary parser keeps the function-designator
                ' lvalue and wraps it in matching parentheses at each grouping
                ' level. Remove only groups that cover the complete name.
                While Left(directProcedureName, 1) = "(" AndAlso _
                      Right(directProcedureName, 1) = ")"
                    Dim directNameGroupEnd As Long = 1
                    If ScanSimpleExpressionGroup( _
                        directProcedureName, directNameGroupEnd, _
                        Asc("("), Asc(")")) = 0 OrElse _
                       directNameGroupEnd <> Len(directProcedureName) + 1 Then _
                        Exit While
                    directProcedureName = Trim(Mid( _
                        directProcedureName, 2, Len(directProcedureName) - 2))
                Wend
            End If
            If directProcedureName <> "" AndAlso _
               CBodyProcedureIndex( _
                   parser.translation[0], directProcedureName) < 0 AndAlso _
               C2fbNameListContains( _
                   callableNames(), callableCount, directProcedureName) = 0 Then _
                directProcedureName = ""
            If directProcedureName <> "" Then
                value.isFunctionDesignator = 0
                value.text = CBodyCallName( _
                    parser.translation[0], parser.catalog[0], _
                    directProcedureName)
                value.typeName = CBodyReturnType( _
                    parser.translation[0], parser.catalog[0], _
                    directProcedureName)
                If value.text = "" OrElse value.typeName = "" Then Return 0
                If ParseSimpleCallValue( _
                    parser, value, directProcedureName, depth, callableNames(), _
                    callableCount, parameterNames(), parameterAliases(), _
                    parameterTypes(), parameterCount) = 0 Then Return 0
            Else
                If IsCBodyCallbackTypeInContext( _
                    parser.translation[0], value.typeName) = 0 Then Return 0
                If ParseSimpleCallValue( _
                    parser, value, "", depth, callableNames(), callableCount, _
                    parameterNames(), parameterAliases(), parameterTypes(), _
                    parameterCount) = 0 Then Return 0
            End If
        ElseIf suffix = "++" OrElse suffix = "--" Then
            parser.position += 2
            If ApplySimpleIncrement(parser, value, (suffix = "--"), -1) = 0 Then Return 0
        Else
            Exit Do
        End If
    Loop
    ' A C array used without an index decays to its first element's address.
    If value.isLayoutArray <> 0 Then
        If value.arrayRank > 1 AndAlso parser.unevaluated = 0 Then
            Dim dimensionBounds() As String
            Dim dimensionBoundCount As Long
            If SplitSimpleCList( _
                value.arrayDimensions, dimensionBounds(), _
                dimensionBoundCount) = 0 OrElse _
               dimensionBoundCount <> value.arrayRank OrElse _
               value.arrayElementType = "" Then Return 0
            Dim rowElementCount As LongInt = 1
            For dimensionIndex As Long = 1 To value.arrayRank - 1
                Dim dimensionCount As Long
                If EvaluateSimpleArrayBound( _
                    dimensionBounds(dimensionIndex), dimensionCount, _
                    MAX_GENERIC_ARRAY_COUNT) = 0 OrElse dimensionCount < 1 OrElse _
                   rowElementCount > _
                       (MAX_GENERIC_ARRAY_COUNT \ dimensionCount) Then Return 0
                rowElementCount *= dimensionCount
            Next
            value.text = "CPtr(" & value.arrayElementType & " Ptr, @(" & _
                value.text & "(0)))"
            value.typeName = value.arrayElementType & " Ptr"
            value.layoutType = value.typeName
            value.storageType = value.typeName
            value.isPointerToArray = -1
            value.pointerToArrayElementCount = CLng(rowElementCount)
            value.isLValue = 0
            value.lValueText = ""
            value.arrayCount = 0
            value.arrayBound = ""
            value.arrayRank = 0
            value.arrayDimensions = ""
            value.arrayElementType = ""
            value.arraySourceName = ""
            value.isLayoutArray = 0
            value.isAlignedArray = 0
        ElseIf value.isAlignedArray <> 0 Then
            ' The backing Basic object is already a pointer rounded to the
            ' requested C alignment, so array decay keeps that pointer value.
            value.typeName = value.arrayElementType & " Ptr"
            value.layoutType = value.typeName
            value.storageType = value.typeName
            value.isLValue = 0
            value.lValueText = ""
            If parser.unevaluated = 0 Then
                value.arrayCount = 0
                value.arrayBound = ""
                value.arrayRank = 0
                value.arrayDimensions = ""
                value.arrayElementType = ""
                value.arraySourceName = ""
                value.isLayoutArray = 0
                value.isAlignedArray = 0
            End If
        Else
            value.text = "(@" & value.text & "(0))"
            If InStr(value.typeName, " Ptr") <> 0 Then _
                value.text = "CPtr(" & value.typeName & ", " & value.text & ")"
            value.isLayoutArray = 0
        End If
    End If
    NormalizeSimpleVolatileTypedefPointer(parser, value)
    Return -1
End Function

/' ------------------------------------------------------------------------- '/
/' Binary and conditional expressions                                        '/
/' ------------------------------------------------------------------------- '/

Private Function SimpleBinaryPrecedence(ByVal operatorText As String) As Long
    ' Higher values bind more tightly. The low levels are comma, assignment,
    ' and conditional; arithmetic levels follow the C grammar.
    Select Case operatorText
    Case ",": Return 1
    Case "=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "^=", "|=": Return 2
    Case "?": Return 3
    Case "||": Return 4
    Case "&&": Return 5
    Case "|": Return 6
    Case "^": Return 7
    Case "&": Return 8
    Case "==", "!=": Return 9
    Case "<", "<=", ">", ">=": Return 10
    Case "<<", ">>": Return 11
    Case "+", "-": Return 12
    Case "*", "/", "%": Return 13
    End Select
    Return 0
End Function

Private Function ApplySimpleBinaryValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue, _
    ByRef rightValue As SimpleExpressionValue, ByVal operatorText As String _
) As Long
    If value.typeName = "void" OrElse rightValue.typeName = "void" Then Return 0
    If operatorText <> "&&" AndAlso operatorText <> "||" Then
        value.logicalOperator = ""
        value.logicalCondition = ""
    End If
    If operatorText = "/" AndAlso value.sizeOfArrayCount > 0 AndAlso _
       value.sizeOfArraySourceName <> "" AndAlso _
       value.sizeOfArraySourceName = rightValue.sizeOfArrayElementSourceName Then
        ' C uses sizeof(array)/sizeof(array[0]) as its portable element count.
        ' Preserve that count without depending on the mapped record's byte size.
        value.text = "Cast(c2fb_size_t, " & _
            Trim(Str(value.sizeOfArrayCount)) & "ULL)"
        value.typeName = "c2fb_size_t"
        value.layoutType = value.typeName
        value.storageType = value.typeName
        value.isLValue = 0
        value.lValueText = ""
        value.sizeOfArraySourceName = ""
        value.sizeOfArrayElementSourceName = ""
        value.sizeOfArrayCount = 0
        Return -1
    End If
    If operatorText = "&&" OrElse operatorText = "||" Then
        Dim leftCondition As String
        If value.logicalOperator = operatorText Then
            leftCondition = value.logicalCondition
        Else
            leftCondition = SimpleScalarTruthCondition( _
                parser.translation[0], parser.catalog[0], value)
        End If
        Dim rightCondition As String
        If rightValue.logicalOperator = operatorText Then
            rightCondition = rightValue.logicalCondition
        Else
            rightCondition = SimpleScalarTruthCondition( _
                parser.translation[0], parser.catalog[0], rightValue)
        End If
        If leftCondition = "" OrElse rightCondition = "" Then Return 0
        Dim fbOperator As String = "AndAlso"
        If operatorText = "||" Then fbOperator = "OrElse"
        value.logicalOperator = operatorText
        value.logicalCondition = leftCondition & " " & fbOperator & " " & rightCondition
        value.text = SimpleBooleanValue( _
            "(" & value.logicalCondition & ")")
        value.typeName = "c2fb_c_int"
        value.layoutType = value.typeName
        value.storageType = value.typeName
        value.isLValue = 0
        value.lValueText = ""
        value.cRecord = ""
        value.isWholeCall = 0
        value.arrayCount = 0
        value.arrayBound = ""
        parser.hasBooleanOperator = -1
        Return -1
    End If
    Dim leftPointee As String = SimplePointeeType(value.typeName)
    Dim rightPointee As String = SimplePointeeType(rightValue.typeName)
    If operatorText = "+" OrElse operatorText = "-" Then
        Dim pointerType As String
        If leftPointee <> "" AndAlso rightPointee <> "" Then
            If operatorText <> "-" OrElse leftPointee <> rightPointee OrElse leftPointee = "Any" Then Return 0
            ' hDoPointerArith() in ast-node-bop.bas divides the byte difference
            ' by the element size and returns a native signed INTEGER.
            pointerType = leftPointee & " Ptr"
            value.text = "(CPtr(" & pointerType & ", " & SimpleCharacterPointer(value) & _
                ") - CPtr(" & pointerType & ", " & SimpleCharacterPointer(rightValue) & "))"
            value.typeName = "Integer"
        ElseIf leftPointee <> "" AndAlso leftPointee <> "Any" AndAlso _
               SimpleArithmeticKindIsInteger( _
                   SimpleArithmeticKind(parser.catalog[0], rightValue.typeName)) <> 0 Then
            pointerType = value.typeName
            value.text = "CPtr(" & pointerType & ", (" & SimpleCharacterPointer(value) & " " & operatorText & " " & rightValue.text & "))"
            value.typeName = pointerType
        ElseIf operatorText = "+" AndAlso rightPointee <> "" AndAlso rightPointee <> "Any" AndAlso _
               SimpleArithmeticKindIsInteger( _
                   SimpleArithmeticKind(parser.catalog[0], value.typeName)) <> 0 Then
            pointerType = rightValue.typeName
            value.text = "CPtr(" & pointerType & ", (" & value.text & " + " & SimpleCharacterPointer(rightValue) & "))"
            value.typeName = pointerType
        End If
        If pointerType <> "" OrElse (leftPointee <> "" AndAlso rightPointee <> "") Then
            value.layoutType = value.typeName
            value.storageType = value.typeName
            value.cRecord = CBodyRecordName(parser.translation[0], parser.catalog[0], value.typeName)
            value.isLValue = 0
            value.lValueText = ""
            value.isWholeCall = 0
            value.arrayCount = 0
            value.arrayBound = ""
            Return -1
        End If
    End If
    Dim commonType As String = SimpleCommonArithmeticType( _
        parser.catalog[0], value.typeName, rightValue.typeName)
    Dim commonKind As Long = SimpleArithmeticKind( _
        parser.catalog[0], commonType)
    If SimpleArithmeticKindIsFloating(commonKind) <> 0 AndAlso _
       (operatorText = "&" OrElse operatorText = "|" OrElse _
        operatorText = "^" OrElse operatorText = "%") Then Return 0
    Dim leftText As String = SimpleValueCast(parser.translation[0], parser.catalog[0], value, commonType)
    Dim rightText As String = SimpleValueCast(parser.translation[0], parser.catalog[0], rightValue, commonType)
    Dim fbOperator As String = operatorText
    Dim isBoolean As Long = 0
    If (operatorText = "==" OrElse operatorText = "!=") AndAlso _
       (IsCBodyCallbackTypeInContext(parser.translation[0], value.typeName) <> 0 OrElse IsCBodyCallbackTypeInContext(parser.translation[0], rightValue.typeName) <> 0) Then
        ' Function pointers and opaque data pointers are distinct BASIC
        ' types. C destructor sentinel comparisons compare their addresses.
        leftText = "CPtr(Any Ptr, " & leftText & ")"
        rightText = "CPtr(Any Ptr, " & rightText & ")"
    End If
    Select Case operatorText
    Case "==": fbOperator = "=": isBoolean = -1
    Case "!=": fbOperator = "<>": isBoolean = -1
    Case "<", "<=", ">", ">=": isBoolean = -1
    Case "&&": fbOperator = "AndAlso": isBoolean = -1
    Case "||": fbOperator = "OrElse": isBoolean = -1
    Case "&": fbOperator = "And"
    Case "|": fbOperator = "Or"
    Case "^": fbOperator = "Xor"
    Case "%": fbOperator = "Mod"
    Case "/"
        ' C chooses integer or floating division from its operand types.
        ' An unknown field or call result cannot safely choose / or \.
        If Len(commonType) = 0 Then Return 0
        If SimpleArithmeticKindIsInteger( _
            SimpleArithmeticKind(parser.catalog[0], commonType)) <> 0 Then _
            fbOperator = "\"
    Case "<<", ">>"
        commonType = SimpleArithmeticType(SimpleArithmeticKind(parser.catalog[0], value.typeName))
        If SimpleArithmeticKindIsInteger( _
            SimpleArithmeticKind(parser.catalog[0], commonType)) = 0 Then Return 0
        leftText = SimpleValueCast(parser.translation[0], parser.catalog[0], value, commonType)
        rightText = rightValue.text
        fbOperator = IIf(operatorText = "<<", "Shl", "Shr")
    End Select
    value.text = "(" & leftText & " " & fbOperator & " " & rightText & ")"
    value.typeName = commonType
    value.isLValue = 0
    value.cRecord = ""
    value.lValueText = ""
    value.isWholeCall = 0
    value.arrayCount = 0
    value.arrayBound = ""
    If isBoolean <> 0 Then
        value.text = SimpleBooleanValue(value.text)
        value.typeName = "c2fb_c_int"
        parser.hasBooleanOperator = -1
    ElseIf Len(commonType) <> 0 Then
        ' FreeBASIC promotes arithmetic to at least its target INTEGER
        ' width. C unsigned int operations must wrap at 32 bits before
        ' division, comparison, or promotion by the next expression node.
        value.text = "Cast(" & commonType & ", " & value.text & ")"
        value.text = SimpleFloatingValue(value.text, commonType)
    End If
    value.layoutType = value.typeName
    value.storageType = value.typeName
    Return -1
End Function

Private Function ApplySimpleAssignment( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue, _
    ByRef rightValue As SimpleExpressionValue, ByVal operatorText As String _
) As Long
    If rightValue.typeName = "void" Then Return 0
    Dim storage As String
    If CaptureSimpleStorage(parser, value, storage) = 0 Then
        If parser.context <> 0 Then _
            RecordSimpleBodyFailure(parser.context[0], _
                "assignment-target-not-writable", _
                "assignment target is not writable: C type=" & value.typeName & _
                ", storage=" & value.storageType & _
                ", record=" & value.cRecord & ", layout=" & value.layoutType & _
                ", expression=" & Left(value.text, 60) & _
                ", lvalue expression=" & Left(value.lValueText, 60) & _
                ", lvalue=" & Trim(Str(value.isLValue)) & _
                ", const=" & Trim(Str(value.isReadOnly)) & _
                ", bit width=" & Trim(Str(value.bitWidth)))
        Return 0
    End If
    Dim volatileTarget As SimpleExpressionValue = value
    Dim isVolatileTarget As Long = _
        SimpleValueHasVolatileAccess(volatileTarget)
    Dim isVolatilePointerTarget As Long = _
        SimpleValueHasVolatilePointerAccess(volatileTarget)
    If isVolatileTarget <> 0 AndAlso isVolatilePointerTarget = 0 AndAlso _
       (value.pointerCount <> 0 OrElse _
        SimpleIntegerWidthInBits( _
            parser.catalog[0], value.typeName) = 0) Then
        If parser.context <> 0 Then _
            RecordSimpleBodyFailure( _
                parser.context[0], "unsupported-volatile-store", _
                "volatile stores require a supported pointer or integer type")
        Return 0
    End If
    Dim targetType As String = value.typeName
    Dim storageType As String = value.storageType
    Dim directBitWidth As Long = value.bitWidth
    Dim isDirectBitField As Long = value.isDirectBitField
    Dim isPackedBitField As Long = value.isPackedBitField
    Dim bitOffset As Long = value.bitOffset
    Dim isUnsignedBitField As Long = value.isUnsignedBitField
    Dim isSignedBitField As Long = value.isSignedBitField
    Dim statements As String = value.prelude & rightValue.prelude
    If operatorText <> "=" Then
        If isVolatilePointerTarget <> 0 AndAlso _
           value.volatileReadLowered = 0 Then
            Dim volatileRead As String
            If BuildCBodyVolatileLoad( _
                parser, value, storage, volatileRead) = 0 Then
                RecordSimpleBodyFailure( _
                    parser.context[0], "unsupported-volatile-load", _
                    "could not lower volatile load: " & _
                    Left(value.lValueText, 120))
                Return 0
            End If
            value.text = volatileRead
            value.isWholeCall = -1
            value.volatileReadLowered = -1
            parser.hasFunctionCall = -1
        End If
        If ApplySimpleBinaryValue(parser, value, rightValue, Left(operatorText, Len(operatorText) - 1)) = 0 Then
            If parser.context <> 0 Then _
                RecordSimpleBodyFailure(parser.context[0], _
                    "unsupported-compound-assignment", _
                    "compound assignment operator is unsupported: " & operatorText)
            Return 0
        End If
        rightValue = value
    End If
    Dim converted As String = SimpleConvertedValue( _
        parser.translation[0], parser.catalog[0], rightValue, targetType)
    If converted = "" Then
        If parser.context <> 0 Then _
            RecordSimpleBodyFailure(parser.context[0], _
                "unsupported-assignment-conversion", _
                "assignment conversion is unsupported: " & _
                rightValue.typeName & " to " & targetType)
        Return 0
    End If
    Dim result As String = NewSimpleTemporary(parser, targetType)
    If result = "" Then
        If parser.context <> 0 Then _
            RecordSimpleBodyFailure(parser.context[0], _
                "assignment-temporary-allocation-failed", _
                "could not allocate an assignment temporary for " & targetType)
        Return 0
    End If
    ' Freeze the converted right-hand side before storing it. Otherwise a
    ' function call or other side effect can be evaluated again by the store.
    Dim valueForStorage As String = result
    Dim valueAfterStorage As String = storage
    If storageType <> "" AndAlso storageType <> targetType Then
        Dim storedExpression As SimpleExpressionValue = rightValue
        storedExpression.text = result
        storedExpression.typeName = targetType
        valueForStorage = SimpleValueCast(parser.translation[0], parser.catalog[0], storedExpression, storageType)
        If valueForStorage = "" Then Return 0

        Dim loadedExpression As SimpleExpressionValue = value
        loadedExpression.text = storage
        loadedExpression.typeName = storageType
        valueAfterStorage = SimpleValueCast(parser.translation[0], parser.catalog[0], loadedExpression, targetType)
        If valueAfterStorage = "" Then Return 0
    End If
    If isDirectBitField <> 0 OrElse isPackedBitField <> 0 Then
        If SimpleBitFieldStoredValues( _
            parser, targetType, storageType, isPackedBitField, _
            isSignedBitField, isUnsignedBitField, directBitWidth, bitOffset, _
            storage, result, valueForStorage, valueAfterStorage) = 0 Then Return 0
    End If
    ' The result has the type and value after assignment conversion, rather
    ' than the promoted type of a compound operation. It is not a C lvalue.
    value.prelude = statements & result & " = " & converted & Chr(10)
    If isDirectBitField <> 0 OrElse isPackedBitField <> 0 Then _
        value.prelude &= result & " = " & valueAfterStorage & Chr(10)
    If isVolatilePointerTarget <> 0 Then
        Dim volatileStore As String
        If BuildCBodyVolatileStore( _
            parser, volatileTarget, storage, valueForStorage, _
            volatileStore) = 0 Then
            RecordSimpleBodyFailure( _
                parser.context[0], "unsupported-volatile-store", _
                "could not lower volatile store: " & _
                Left(volatileTarget.lValueText, 120))
            Return 0
        End If
        value.prelude &= volatileStore & Chr(10)
    Else
        value.prelude &= storage & " = " & valueForStorage & Chr(10)
    End If
    If storageType <> "" AndAlso storageType <> targetType Then _
        value.prelude &= result & " = " & valueAfterStorage & Chr(10)
    value.text = result
    value.typeName = targetType
    value.layoutType = targetType
    value.storageType = targetType
    value.pointerCount = volatileTarget.pointerCount
    value.volatileMask = volatileTarget.volatileMask And _
        Not(1 Shl volatileTarget.pointerCount)
    value.volatileReadLowered = 0
    value.isLValue = 0
    value.lValueText = ""
    value.cRecord = CBodyRecordName(parser.translation[0], parser.catalog[0], targetType)
    value.isWholeCall = 0
    value.arrayBound = ""
    value.arrayCount = 0
    value.bitWidth = -1
    value.isDirectBitField = 0
    value.isUnsignedBitField = 0
    value.isSignedBitField = 0
    value.bitFieldOwnerText = ""
    value.bitFieldOwnerType = ""
    value.bitFieldName = ""
    value.bitFieldOwnerIsPointer = 0
    Return -1
End Function

Private Function ParseSimpleExpressionValue( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal minimumPrecedence As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH Then Return 0
    If parser.simpleGnuExpressionsNormalized = 0 Then
        parser.simpleGnuExpressionsNormalized = -1
        Dim statementExpressionText As String
        If NormalizeSimpleGnuStatementExpressions( _
            parser.sourceText, statementExpressionText) <> 0 Then _
            parser.sourceText = statementExpressionText
    End If
    If ParseSimpleUnaryValue(parser, value, depth, callableNames(), callableCount, _
                             parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then
        Return 0
    End If
    Do
        SkipCSpaces(parser.sourceText, parser.position)
        Dim operatorText As String = Mid(parser.sourceText, parser.position, 3)
        If operatorText <> "<<=" AndAlso operatorText <> ">>=" Then
            operatorText = Left(operatorText, 2)
            Select Case operatorText
            Case "||", "&&", "==", "!=", "<=", ">=", "<<", ">>", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=":
            Case Else: operatorText = Left(operatorText, 1)
            End Select
        End If
        Dim precedence As Long = SimpleBinaryPrecedence(operatorText)
        If precedence <> 2 AndAlso _
           parser.unevaluated = 0 AndAlso _
           value.volatileReadLowered = 0 AndAlso _
           SimpleValueHasVolatileAccess(value) <> 0 Then
            Dim volatileRead As String
            If BuildCBodyVolatileLoad( _
                parser, value, value.lValueText, volatileRead) = 0 Then
                If parser.context <> 0 Then _
                    RecordSimpleBodyFailure( _
                        parser.context[0], "unsupported-volatile-load", _
                        "could not lower volatile load: " & _
                        Left(value.lValueText, 120) & _
                        ", C type=" & value.typeName & _
                        ", pointer count=" & Trim(Str(value.pointerCount)) & _
                        ", volatile mask=" & Trim(Str(value.volatileMask)) & _
                        ", lvalue=" & Trim(Str(value.isLValue)))
                Return 0
            End If
            value.text = volatileRead
            value.isWholeCall = -1
            value.volatileReadLowered = -1
            parser.hasFunctionCall = -1
        End If
        If precedence < minimumPrecedence Then Exit Do
        parser.position += Len(operatorText)
        If operatorText = "?" Then
            Dim trueValue As SimpleExpressionValue
            Dim falseValue As SimpleExpressionValue
            If ParseSimpleExpressionValue(parser, trueValue, 1, depth + 1, callableNames(), callableCount, _
                                          parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
            SkipCSpaces(parser.sourceText, parser.position)
            If Mid(parser.sourceText, parser.position, 1) <> ":" Then Return 0
            parser.position += 1
            If ParseSimpleExpressionValue(parser, falseValue, 3, depth + 1, callableNames(), callableCount, _
                                          parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
            Dim commonType As String = SimpleConditionalType( _
                parser.translation[0], parser.catalog[0], trueValue, falseValue)
            If parser.targetType <> "" AndAlso _
               IsCBodyCallbackTypeInContext( _
                   parser.translation[0], parser.targetType) <> 0 AndAlso _
               ((Left(Trim(trueValue.text), Len("ProcPtr(")) = "ProcPtr(" AndAlso _
                 SimpleIsNullValue(falseValue) <> 0) OrElse _
                (Left(Trim(falseValue.text), Len("ProcPtr(")) = "ProcPtr(" AndAlso _
                 SimpleIsNullValue(trueValue) <> 0)) Then
                commonType = parser.targetType
            End If
            If IsCBodyCallbackTypeInContext( _
                parser.translation[0], commonType) <> 0 AndAlso _
               trueValue.isFunctionDesignator <> 0 AndAlso _
               falseValue.isFunctionDesignator <> 0 Then
                If parser.context = 0 Then Return 0
                Dim callbackTemporary As String = _
                    NewSimpleTemporary(parser, commonType)
                Dim conditionText As String = SimpleScalarTruthCondition( _
                    parser.translation[0], parser.catalog[0], value)
                If callbackTemporary = "" OrElse conditionText = "" Then Return 0
                value.prelude &= "If " & conditionText & " Then" & Chr(10) & _
                    IndentSimpleBodyText( _
                        trueValue.prelude & callbackTemporary & _
                        " = CPtr(" & commonType & ", " & trueValue.text & ")", _
                        "    ") & Chr(10) & "Else" & Chr(10) & _
                    IndentSimpleBodyText( _
                        falseValue.prelude & callbackTemporary & _
                        " = CPtr(" & commonType & ", " & falseValue.text & ")", _
                        "    ") & Chr(10) & "End If" & Chr(10)
                value.text = callbackTemporary
                value.typeName = commonType
                value.layoutType = commonType
                value.storageType = commonType
                value.isLValue = 0
                value.isFunctionDesignator = 0
                value.lValueText = ""
                value.cRecord = ""
                value.isWholeCall = 0
                value.arrayCount = 0
                value.arrayBound = ""
                Continue Do
            End If
            If commonType = "void" OrElse trueValue.prelude <> "" OrElse falseValue.prelude <> "" Then
                If commonType = "void" Then
                    If DiscardSimpleValue(parser, trueValue) = 0 OrElse DiscardSimpleValue(parser, falseValue) = 0 Then Return 0
                    value.prelude &= "If " & value.text & " Then" & Chr(10) & IndentSimpleBodyText(trueValue.prelude, "    ") & _
                                     "Else" & Chr(10) & IndentSimpleBodyText(falseValue.prelude, "    ") & "End If" & Chr(10)
                    value.text = ""
                Else
                    Dim result As String = NewSimpleTemporary(parser, commonType)
                    If result = "" Then Return 0
                    value.prelude &= "If " & value.text & " Then" & Chr(10) & _
                                     IndentSimpleBodyText(trueValue.prelude & result & " = " & SimpleValueCast(parser.translation[0], parser.catalog[0], trueValue, commonType), "    ") & Chr(10) & _
                                     "Else" & Chr(10) & _
                                     IndentSimpleBodyText(falseValue.prelude & result & " = " & SimpleValueCast(parser.translation[0], parser.catalog[0], falseValue, commonType), "    ") & Chr(10) & _
                                     "End If" & Chr(10)
                    value.text = result
                End If
            Else
                ' ast-node-iif.bas lowers only the selected branch, as C requires.
                value.text = "IIf(" & value.text & ", " & SimpleValueCast(parser.translation[0], parser.catalog[0], trueValue, commonType) & _
                             ", " & SimpleValueCast(parser.translation[0], parser.catalog[0], falseValue, commonType) & ")"
            End If
            value.typeName = commonType
            value.layoutType = commonType
            value.storageType = commonType
            value.isLValue = 0
            value.cRecord = CBodyRecordName(parser.translation[0], parser.catalog[0], commonType)
            value.lValueText = ""
            value.isWholeCall = 0
            value.arrayCount = 0
            value.arrayBound = ""
            Continue Do
        End If
        Dim rightValue As SimpleExpressionValue
        Dim rightPrecedence As Long = precedence + 1
        If precedence = 2 Then rightPrecedence = precedence
        If ParseSimpleExpressionValue(parser, rightValue, rightPrecedence, depth + 1, callableNames(), callableCount, _
                                      parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
        If precedence = 2 Then
            If parser.unevaluated <> 0 Then
                If value.isLValue = 0 Then Return 0
                value.isLValue = 0
            Else
                If ApplySimpleAssignment(parser, value, rightValue, operatorText) = 0 Then Return 0
            End If
        ElseIf operatorText = "," Then
            If parser.unevaluated = 0 Then
                If DiscardSimpleValue(parser, value) = 0 Then Return 0
                rightValue.prelude = value.prelude & rightValue.prelude
            End If
            value = rightValue
            value.isLValue = 0
            value.lValueText = ""
            value.arrayCount = 0
            value.arrayBound = ""
        ElseIf (operatorText = "&&" OrElse operatorText = "||") AndAlso rightValue.prelude <> "" Then
            Dim leftCondition As String
            If value.logicalOperator = operatorText Then
                leftCondition = value.logicalCondition
            Else
                leftCondition = SimpleScalarTruthCondition( _
                    parser.translation[0], parser.catalog[0], value)
            End If
            Dim rightCondition As String
            If rightValue.logicalOperator = operatorText Then
                rightCondition = rightValue.logicalCondition
            Else
                rightCondition = SimpleScalarTruthCondition( _
                    parser.translation[0], parser.catalog[0], rightValue)
            End If
            If leftCondition = "" OrElse rightCondition = "" Then Return 0
            Dim result As String = NewSimpleTemporary(parser, "c2fb_c_int")
            If result = "" Then Return 0
            Dim condition As String = leftCondition
            If operatorText = "||" Then
                ' Keep a prior OR chain grouped before comparing it with zero.
                ' FreeBASIC binds the comparison more tightly than OrElse.
                condition = "((" & leftCondition & ") = 0)"
            End If
            value.prelude &= result & " = " & IIf(operatorText = "||", "1", "0") & Chr(10) & _
                             "If " & condition & " Then" & Chr(10) & _
                             IndentSimpleBodyText(rightValue.prelude & result & " = " & SimpleBooleanValue(rightCondition), "    ") & Chr(10) & _
                             "End If" & Chr(10)
            value.text = result
            value.typeName = "c2fb_c_int"
            value.layoutType = value.typeName
            value.storageType = value.typeName
            value.isLValue = 0
            value.lValueText = ""
            value.isWholeCall = 0
            value.logicalOperator = ""
            value.logicalCondition = ""
            parser.hasBooleanOperator = -1
        Else
            If rightValue.prelude <> "" Then
                If FreezeSimpleValue(parser, value) = 0 Then Return 0
            End If
            value.prelude &= rightValue.prelude
            If ApplySimpleBinaryValue(parser, value, rightValue, operatorText) = 0 Then Return 0
        End If
    Loop
    Return -1
End Function

Private Function NormalizeGnulibCountofElementSizeof( _
    ByVal sourceExpression As String, ByRef normalizedExpression As String _
) As Long
    normalizedExpression = sourceExpression
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        If LCase(Mid(sourceExpression, position, 6)) <> "sizeof" Then
            position += 1
            Continue While
        End If
        Dim nextByte As Long = position + 6
        If nextByte <= Len(sourceExpression) AndAlso _
           IsIdentifierPart(Asc(sourceExpression, nextByte)) <> 0 Then
            position += 6
            Continue While
        End If
        SkipCSpaces(sourceExpression, nextByte)
        If nextByte > Len(sourceExpression) OrElse _
           Asc(sourceExpression, nextByte) <> Asc("(") Then
            position += 6
            Continue While
        End If

        Dim groupEnd As Long = nextByte
        If ScanSimpleExpressionGroup( _
            sourceExpression, groupEnd, Asc("("), Asc(")")) = 0 Then Return 0
        Dim subscriptPosition As Long = groupEnd
        SkipCSpaces(sourceExpression, subscriptPosition)
        If subscriptPosition > Len(sourceExpression) OrElse _
           Asc(sourceExpression, subscriptPosition) <> Asc("[") Then
            position = groupEnd
            Continue While
        End If
        subscriptPosition += 1
        SkipCSpaces(sourceExpression, subscriptPosition)
        If subscriptPosition > Len(sourceExpression) OrElse _
           Asc(sourceExpression, subscriptPosition) <> Asc("0") Then
            position = groupEnd
            Continue While
        End If
        subscriptPosition += 1
        SkipCSpaces(sourceExpression, subscriptPosition)
        If subscriptPosition > Len(sourceExpression) OrElse _
           Asc(sourceExpression, subscriptPosition) <> Asc("]") Then
            position = groupEnd
            Continue While
        End If
        subscriptPosition += 1

        normalizedExpression = _
            Left(sourceExpression, nextByte) & _
            Mid(sourceExpression, nextByte + 1, groupEnd - nextByte - 2) & _
            "[0])" & Mid(sourceExpression, subscriptPosition)
        Return -1
    Wend
    Return 0
End Function

Private Function StripGnulibCountofArrayTypeCheck( _
    ByVal sourceExpression As String, ByRef normalizedExpression As String _
) As Long
    normalizedExpression = sourceExpression
    Dim plusPosition As Long = 1
    While plusPosition <= Len(sourceExpression)
        If Asc(sourceExpression, plusPosition) <> Asc("+") Then
            plusPosition += 1
            Continue While
        End If

        Dim checkPosition As Long = plusPosition + 1
        SkipCSpaces(sourceExpression, checkPosition)
        If checkPosition > Len(sourceExpression) OrElse _
           Asc(sourceExpression, checkPosition) <> Asc("0") Then
            plusPosition += 1
            Continue While
        End If
        checkPosition += 1
        SkipCSpaces(sourceExpression, checkPosition)
        If checkPosition > Len(sourceExpression) OrElse _
           Asc(sourceExpression, checkPosition) <> Asc("*") Then
            plusPosition += 1
            Continue While
        End If
        checkPosition += 1
        SkipCSpaces(sourceExpression, checkPosition)
        If LCase(Mid(sourceExpression, checkPosition, 6)) <> "sizeof" Then
            plusPosition += 1
            Continue While
        End If
        checkPosition += 6
        If checkPosition <= Len(sourceExpression) AndAlso _
           IsIdentifierPart(Asc(sourceExpression, checkPosition)) <> 0 Then
            plusPosition += 1
            Continue While
        End If
        SkipCSpaces(sourceExpression, checkPosition)
        If checkPosition > Len(sourceExpression) OrElse _
           Asc(sourceExpression, checkPosition) <> Asc("(") Then
            plusPosition += 1
            Continue While
        End If

        Dim groupEnd As Long = checkPosition
        If ScanSimpleExpressionGroup( _
            sourceExpression, groupEnd, Asc("("), Asc(")")) = 0 Then
            plusPosition += 1
            Continue While
        End If
        Dim typeCheck As String = Mid( _
            sourceExpression, checkPosition + 1, groupEnd - checkPosition - 2)
        If InStr(LCase(typeCheck), "_gl_verify_error_if_negative") = 0 OrElse _
           InStr(typeCheck, ":") = 0 OrElse _
           InStr(LCase(typeCheck), "struct") = 0 Then
            plusPosition += 1
            Continue While
        End If

        ' The C compiler has already checked the gnulib array guard. Its
        ' zero-times-sizeof term contributes no value to the valid expression.
        Dim withoutTypeCheck As String = _
            Left(sourceExpression, plusPosition - 1) & _
            Mid(sourceExpression, groupEnd)
        Dim normalizedCount As String
        If NormalizeGnulibCountofElementSizeof( _
            withoutTypeCheck, normalizedCount) <> 0 Then
            normalizedExpression = normalizedCount
        Else
            normalizedExpression = withoutTypeCheck
        End If
        Return -1
    Wend
    Return 0
End Function

Private Function IsSimpleGnuStatementExpressionAlias( _
    ByVal sourceText As String, ByRef aliasName As String _
) As Long
    ' Obstack size macros use a single local pointer alias. Inline only a
    ' plain object name or a member-access chain, optionally taking its
    ' address. Substitution cannot repeat a call or indexed side effect that
    ' C would evaluate once.
    sourceText = Trim(sourceText)
    While Len(sourceText) >= 2 AndAlso Left(sourceText, 1) = "(" AndAlso _
          Right(sourceText, 1) = ")"
        Dim groupEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceText, groupEnd, Asc("("), Asc(")")) = 0 OrElse _
           groupEnd <> Len(sourceText) + 1 Then Exit While
        sourceText = Trim(Mid(sourceText, 2, Len(sourceText) - 2))
    Wend

    If Left(sourceText, 1) = "&" Then
        sourceText = Trim(Mid(sourceText, 2))
        While Len(sourceText) >= 2 AndAlso _
              Left(sourceText, 1) = "(" AndAlso _
              Right(sourceText, 1) = ")"
            Dim addressGroupEnd As Long = 1
            If ScanSimpleExpressionGroup( _
                sourceText, addressGroupEnd, Asc("("), Asc(")")) = 0 OrElse _
               addressGroupEnd <> Len(sourceText) + 1 Then Exit While
            sourceText = Trim(Mid( _
                sourceText, 2, Len(sourceText) - 2))
        Wend
    End If
    If sourceText = "" OrElse _
       IsIdentifierStart(Asc(sourceText, 1)) = 0 Then Return 0
    Dim position As Long = 2
    While position <= Len(sourceText) AndAlso _
          IsIdentifierPart(Asc(sourceText, position)) <> 0
        position += 1
    Wend
    While position <= Len(sourceText)
        SkipCSpaces(sourceText, position)
        If position > Len(sourceText) Then Exit While
        If Mid(sourceText, position, 2) = "->" Then
            position += 2
        ElseIf Asc(sourceText, position) = Asc(".") Then
            position += 1
        Else
            Return 0
        End If
        SkipCSpaces(sourceText, position)
        If position > Len(sourceText) OrElse _
           IsIdentifierStart(Asc(sourceText, position)) = 0 Then Return 0
        position += 1
        While position <= Len(sourceText) AndAlso _
              IsIdentifierPart(Asc(sourceText, position)) <> 0
            position += 1
        Wend
    Wend
    aliasName = sourceText
    Return -1
End Function

Private Function IsSimpleGnuIntegerAliasType(ByVal typeName As String) As Long
    typeName = LCase(Trim(typeName))
    Select Case typeName
    Case "char", "signed char", "unsigned char", _
         "short", "short int", "signed short", "signed short int", _
         "unsigned short", "unsigned short int", "int", "signed", _
         "signed int", "unsigned", "unsigned int", "long", "long int", _
         "signed long", "signed long int", "unsigned long", _
         "unsigned long int", "long long", "long long int", _
         "signed long long", "signed long long int", _
         "unsigned long long", "unsigned long long int", "_bool"
        Return -1
    Case Else
        Return 0
    End Select
End Function

Private Function IsSimpleGnuIdentifierAlias( _
    ByVal sourceText As String, ByRef aliasName As String _
) As Long
    sourceText = Trim(sourceText)
    While Len(sourceText) >= 2 AndAlso Left(sourceText, 1) = "(" AndAlso _
          Right(sourceText, 1) = ")"
        Dim groupEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceText, groupEnd, Asc("("), Asc(")")) = 0 OrElse _
           groupEnd <> Len(sourceText) + 1 Then Exit While
        sourceText = Trim(Mid(sourceText, 2, Len(sourceText) - 2))
    Wend
    If sourceText = "" OrElse _
       IsIdentifierStart(Asc(sourceText, 1)) = 0 Then Return 0
    Dim position As Long = 2
    While position <= Len(sourceText) AndAlso _
          IsIdentifierPart(Asc(sourceText, position)) <> 0
        position += 1
    Wend
    If position <= Len(sourceText) Then Return 0
    aliasName = sourceText
    Return -1
End Function

Private Function ReplaceSimpleGnuStatementExpressionAlias( _
    ByVal sourceText As String, ByVal aliasName As String, _
    ByVal initializer As String, ByRef didReplace As Long _
) As String
    Dim result As String
    Dim position As Long = 1
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    didReplace = 0
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
        ElseIf currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
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
            Dim priorPosition As Long = Len(result)
            While priorPosition > 0 AndAlso _
                  IsSpaceByte(Asc(result, priorPosition)) <> 0
                priorPosition -= 1
            Wend
            If token = aliasName AndAlso _
               (priorPosition = 0 OrElse _
                Asc(result, priorPosition) <> Asc(".")) Then
                result &= "(" & initializer & ")"
                didReplace = -1
            Else
                result &= token
            End If
        Else
            result &= Chr(currentByte)
            position += 1
        End If
    Wend
    Return result
End Function

Private Function NormalizeSimpleGnuStatementExpressionAt( _
    ByVal sourceText As String, ByVal extensionPosition As Long, _
    ByRef normalizedExpression As String, ByRef endPosition As Long _
) As Long
    normalizedExpression = ""
    endPosition = extensionPosition
    Const extensionToken As String = "__extension__"
    If Mid(sourceText, extensionPosition, Len(extensionToken)) <> extensionToken Then _
        Return 0
    Dim afterToken As Long = extensionPosition + Len(extensionToken)
    If afterToken <= Len(sourceText) AndAlso _
       IsIdentifierPart(Asc(sourceText, afterToken)) <> 0 Then Return 0
    SkipCSpaces(sourceText, afterToken)
    If afterToken > Len(sourceText) OrElse _
       Asc(sourceText, afterToken) <> Asc("(") Then Return 0

    Dim expressionEnd As Long = afterToken
    If ScanSimpleExpressionGroup( _
        sourceText, expressionEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim statementBlock As String = Trim(Mid( _
        sourceText, afterToken + 1, expressionEnd - afterToken - 2))
    If Left(statementBlock, 1) <> "{" Then Return 0
    Dim blockEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        statementBlock, blockEnd, Asc("{"), Asc("}")) = 0 OrElse _
       blockEnd <> Len(statementBlock) + 1 Then Return 0

    Dim blockContents As String = Trim(Mid( _
        statementBlock, 2, Len(statementBlock) - 2))
    Dim declarationEnd As Long = InStr(blockContents, ";")
    If declarationEnd <= 1 Then Return 0
    Dim declaration As String = Trim(Left(blockContents, declarationEnd - 1))
    Dim finalStatement As String = Trim(Mid(blockContents, declarationEnd + 1))
    If Right(finalStatement, 1) <> ";" Then Return 0
    finalStatement = Trim(Left(finalStatement, Len(finalStatement) - 1))
    If finalStatement = "" OrElse InStr(finalStatement, ";") <> 0 Then Return 0

    Dim assignmentPosition As Long = InStr(declaration, "=")
    If assignmentPosition <= 1 OrElse _
       Mid(declaration, assignmentPosition + 1, 1) = "=" OrElse _
       (assignmentPosition > 1 AndAlso _
        Mid(declaration, assignmentPosition - 1, 1) = "=") Then Return 0
    Dim declaredTypeAndPointer As String = _
        RTrim(Left(declaration, assignmentPosition - 1))
    Dim initializer As String = Trim(Mid(declaration, assignmentPosition + 1))
    Dim aliasEnd As Long = Len(declaredTypeAndPointer)
    While aliasEnd > 0 AndAlso _
          IsSpaceByte(Asc(declaredTypeAndPointer, aliasEnd)) <> 0
        aliasEnd -= 1
    Wend
    Dim aliasStart As Long = aliasEnd
    While aliasStart > 0 AndAlso _
          IsIdentifierPart(Asc(declaredTypeAndPointer, aliasStart)) <> 0
        aliasStart -= 1
    Wend
    aliasStart += 1
    If aliasStart > aliasEnd OrElse _
       IsIdentifierStart(Asc(declaredTypeAndPointer, aliasStart)) = 0 Then Return 0
    Dim aliasName As String = Mid( _
        declaredTypeAndPointer, aliasStart, aliasEnd - aliasStart + 1)
    Dim typeAndPointer As String = RTrim( _
        Left(declaredTypeAndPointer, aliasStart - 1))
    Dim aliasInitializer As String
    Dim normalizedInitializer As String = initializer
    If Right(typeAndPointer, 1) = "*" Then
        If Trim(Left(typeAndPointer, Len(typeAndPointer) - 1)) = "" OrElse _
           IsSimpleGnuStatementExpressionAlias( _
               initializer, aliasInitializer) = 0 Then Return 0
    Else
        If IsSimpleGnuIntegerAliasType(typeAndPointer) = 0 OrElse _
           IsSimpleGnuIdentifierAlias(initializer, aliasInitializer) = 0 Then _
            Return 0
        ' Keep the C assignment conversion when replacing the temporary name.
        normalizedInitializer = "((" & typeAndPointer & ") (" & _
                               aliasInitializer & "))"
    End If

    Dim didReplace As Long
    normalizedExpression = ReplaceSimpleGnuStatementExpressionAlias( _
        finalStatement, aliasName, normalizedInitializer, didReplace)
    If didReplace = 0 Then
        normalizedExpression = ""
        Return 0
    End If
    endPosition = expressionEnd
    Return -1
End Function

Private Function NormalizeSimpleGnuStatementExpressions( _
    ByVal sourceText As String, ByRef normalizedText As String _
) As Long
    normalizedText = ""
    Dim position As Long = 1
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    Dim changed As Long = 0
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If quoteByte <> 0 Then
            normalizedText &= Chr(currentByte)
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
        ElseIf currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
            normalizedText &= Chr(currentByte)
            position += 1
        ElseIf Mid(sourceText, position, 2) = "/*" Then
            Dim commentEnd As Long = InStr(position + 2, sourceText, "*/")
            If commentEnd = 0 Then
                normalizedText &= Mid(sourceText, position)
                Exit While
            End If
            normalizedText &= Mid(sourceText, position, commentEnd + 2 - position)
            position = commentEnd + 2
        ElseIf Mid(sourceText, position, 2) = "//" Then
            normalizedText &= Mid(sourceText, position)
            Exit While
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceText) AndAlso _
                  IsIdentifierPart(Asc(sourceText, position)) <> 0
                position += 1
            Wend
            Dim token As String = Mid(sourceText, tokenStart, position - tokenStart)
            If token = "__extension__" Then
                Dim expressionText As String
                Dim endPosition As Long
                If NormalizeSimpleGnuStatementExpressionAt( _
                    sourceText, tokenStart, expressionText, endPosition) <> 0 OrElse _
                   NormalizeSimpleGnuCallResultStatementExpressionAt( _
                    sourceText, tokenStart, expressionText, endPosition) <> 0 Then
                    normalizedText &= "(" & expressionText & ")"
                    position = endPosition
                    changed = -1
                    Continue While
                End If
            End If
            normalizedText &= token
        Else
            normalizedText &= Chr(currentByte)
            position += 1
        End If
    Wend
    Return changed
End Function

Private Function ReadSimpleGnuStatementExpressionBlock( _
    ByVal sourceText As String, ByVal extensionPosition As Long, _
    ByRef blockContents As String, ByRef endPosition As Long _
) As Long
    blockContents = ""
    endPosition = extensionPosition
    Const extensionToken As String = "__extension__"
    If Mid(sourceText, extensionPosition, Len(extensionToken)) <> extensionToken Then _
        Return 0
    Dim afterToken As Long = extensionPosition + Len(extensionToken)
    If afterToken <= Len(sourceText) AndAlso _
       IsIdentifierPart(Asc(sourceText, afterToken)) <> 0 Then Return 0
    SkipCSpaces(sourceText, afterToken)
    If afterToken > Len(sourceText) OrElse _
       Asc(sourceText, afterToken) <> Asc("(") Then Return 0

    Dim expressionEnd As Long = afterToken
    If ScanSimpleExpressionGroup( _
        sourceText, expressionEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim statementBlock As String = Trim(Mid( _
        sourceText, afterToken + 1, expressionEnd - afterToken - 2))
    If Left(statementBlock, 1) <> "{" Then Return 0
    Dim blockEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        statementBlock, blockEnd, Asc("{"), Asc("}")) = 0 OrElse _
       blockEnd <> Len(statementBlock) + 1 Then Return 0

    blockContents = Trim(Mid( _
        statementBlock, 2, Len(statementBlock) - 2))
    If blockContents = "" Then Return 0
    endPosition = expressionEnd
    Return -1
End Function

Private Function CompactSimpleGnuStatementText( _
    ByVal sourceText As String _
) As String
    Dim result As String
    For position As Long = 1 To Len(sourceText)
        If IsSpaceByte(Asc(sourceText, position)) = 0 Then _
            result &= Mid(sourceText, position, 1)
    Next
    Return result
End Function

Private Function IsSimpleGnuDirectCallExpression( _
    ByVal sourceText As String _
) As Long
    sourceText = Trim(sourceText)
    While Len(sourceText) >= 2 AndAlso Left(sourceText, 1) = "(" AndAlso _
          Right(sourceText, 1) = ")"
        Dim groupEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceText, groupEnd, Asc("("), Asc(")")) = 0 OrElse _
           groupEnd <> Len(sourceText) + 1 Then Exit While
        sourceText = Trim(Mid(sourceText, 2, Len(sourceText) - 2))
    Wend

    If sourceText = "" OrElse _
       IsIdentifierStart(Asc(sourceText, 1)) = 0 Then Return 0
    Dim position As Long = 2
    While position <= Len(sourceText) AndAlso _
          IsIdentifierPart(Asc(sourceText, position)) <> 0
        position += 1
    Wend
    SkipCSpaces(sourceText, position)
    If position > Len(sourceText) OrElse _
       Asc(sourceText, position) <> Asc("(") Then Return 0
    Dim callEnd As Long = position
    If ScanSimpleExpressionGroup( _
        sourceText, callEnd, Asc("("), Asc(")")) = 0 OrElse _
       callEnd <> Len(sourceText) + 1 Then Return 0
    Return -1
End Function

Private Function CompactSimpleGnuValueExpression( _
    ByVal sourceText As String _
) As String
    sourceText = Trim(sourceText)
    While Len(sourceText) >= 2 AndAlso Left(sourceText, 1) = "(" AndAlso _
          Right(sourceText, 1) = ")"
        Dim groupEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceText, groupEnd, Asc("("), Asc(")")) = 0 OrElse _
           groupEnd <> Len(sourceText) + 1 Then Exit While
        sourceText = Trim(Mid(sourceText, 2, Len(sourceText) - 2))
    Wend
    Return CompactSimpleGnuStatementText(sourceText)
End Function

Private Function NormalizeSimpleGnuCallResultStatementExpressionAt( _
    ByVal sourceText As String, ByVal extensionPosition As Long, _
    ByRef normalizedExpression As String, ByRef endPosition As Long _
) As Long
    normalizedExpression = ""
    endPosition = extensionPosition
    Dim blockContents As String
    If ReadSimpleGnuStatementExpressionBlock( _
        sourceText, extensionPosition, blockContents, endPosition) = 0 Then _
        Return 0

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
    If InStr(typeExpression, "[") <> 0 OrElse _
       IsSimpleGnuDirectCallExpression(typeExpression) = 0 Then Return 0
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
    Dim aliasName As String = Mid(declaration, aliasStart, position - aliasStart)
    SkipCSpaces(declaration, position)
    If position > Len(declaration) OrElse _
       Asc(declaration, position) <> Asc("=") OrElse _
       (position < Len(declaration) AndAlso _
        Asc(declaration, position + 1) = Asc("=")) Then Return 0
    Dim initializer As String = Trim(Mid(declaration, position + 1))
    If initializer = "" OrElse _
       CompactSimpleGnuValueExpression(typeExpression) <> _
       CompactSimpleGnuValueExpression(initializer) OrElse _
       CompactSimpleGnuValueExpression(finalStatement) <> aliasName Then Return 0

    ' A function call cannot have a variably modified return type, so typeof
    ' does not execute it. Returning the one initializer preserves its single
    ' runtime evaluation.
    normalizedExpression = initializer
    Return -1
End Function

Private Function ParseSimpleObstackFreeStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH OrElse parser.context = 0 OrElse _
       parser.translation = 0 OrElse parser.catalog = 0 OrElse _
       parser.translation[0].target.profile <> C2FB_TARGET_GENERIC Then Return 0

    Dim blockContents As String
    Dim endPosition As Long
    If ReadSimpleGnuStatementExpressionBlock( _
        parser.sourceText, extensionPosition, blockContents, endPosition) = 0 Then _
        Return 0
    Dim compactBlock As String = CompactSimpleGnuStatementText(blockContents)
    If Left(compactBlock, Len("structobstack*__o=")) <> _
       "structobstack*__o=" OrElse _
       InStr(compactBlock, ";void*__obj=") = 0 OrElse _
       InStr(compactBlock, "__o->next_free=__o->object_base=(char*)__obj;") = 0 OrElse _
       InStr(compactBlock, "elserpl_obstack_free(__o,__obj);") = 0 Then Return 0
    Dim obstackPointerCompare As Long = _
        InStr(compactBlock, _
            "if((_OBSTACK_CPTR)__o->chunk<(_OBSTACK_CPTR)__obj&&")
    If obstackPointerCompare = 0 Then _
        obstackPointerCompare = InStr(compactBlock, _
            "if((char*)__o->chunk<(char*)__obj&&")
    If obstackPointerCompare = 0 OrElse _
       (InStr(compactBlock, _
           "(_OBSTACK_CPTR)__obj<(_OBSTACK_CPTR)__o->chunk_limit)") = 0 AndAlso _
        InStr(compactBlock, "(char*)__obj<(char*)__o->chunk_limit)") = 0) Then _
        Return 0

    Dim pointerStatementEnd As Long = InStr(blockContents, ";")
    If pointerStatementEnd <= 1 Then Return 0
    Dim pointerDeclaration As String = _
        Trim(Left(blockContents, pointerStatementEnd - 1))
    Dim pointerEquals As Long = InStr(pointerDeclaration, "=")
    If pointerEquals <= 1 OrElse _
       CompactSimpleGnuStatementText( _
           Left(pointerDeclaration, pointerEquals - 1)) <> "structobstack*__o" Then _
        Return 0
    ' A caller can pass an embedded obstack through an address-of field.
    ' Parse that expression directly; the generated helper evaluates it once.
    Dim obstackArgument As String = _
        Trim(Mid(pointerDeclaration, pointerEquals + 1))

    Dim objectStatementEnd As Long = InStr( _
        pointerStatementEnd + 1, blockContents, ";")
    If objectStatementEnd <= pointerStatementEnd + 1 Then Return 0
    Dim objectDeclaration As String = Trim(Mid( _
        blockContents, pointerStatementEnd + 1, _
        objectStatementEnd - pointerStatementEnd - 1))
    Dim objectEquals As Long = InStr(objectDeclaration, "=")
    If objectEquals <= 1 OrElse _
       CompactSimpleGnuStatementText( _
           Left(objectDeclaration, objectEquals - 1)) <> "void*__obj" Then _
        Return 0
    Dim objectExpression As String = Trim( _
        Mid(objectDeclaration, objectEquals + 1))

    Dim pointerParser As SimpleExpressionParser
    pointerParser.sourceText = obstackArgument
    pointerParser.position = 1
    pointerParser.targetType = "Any Ptr"
    pointerParser.translation = parser.translation
    pointerParser.catalog = parser.catalog
    pointerParser.context = parser.context
    pointerParser.simpleGnuExpressionsNormalized = 0
    pointerParser.hasRuntimeValue = 0
    Dim pointerValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        pointerParser, pointerValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(pointerParser.sourceText, pointerParser.position)
    If pointerParser.position <= Len(pointerParser.sourceText) OrElse _
       pointerValue.prelude <> "" OrElse _
       Right(pointerValue.typeName, 4) <> " Ptr" Then Return 0
    Dim obstackType As String = Left( _
        pointerValue.typeName, Len(pointerValue.typeName) - 4)
    If Left(obstackType, 6) = "Const " OrElse _
       CBodyRecordName( _
           parser.translation[0], parser.catalog[0], obstackType) = "" Then Return 0

    Dim objectParser As SimpleExpressionParser
    objectParser.sourceText = objectExpression
    objectParser.position = 1
    objectParser.targetType = "Any Ptr"
    objectParser.translation = parser.translation
    objectParser.catalog = parser.catalog
    objectParser.context = parser.context
    objectParser.simpleGnuExpressionsNormalized = 0
    objectParser.hasRuntimeValue = 0
    Dim objectValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        objectParser, objectValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(objectParser.sourceText, objectParser.position)
    If objectParser.position <= Len(objectParser.sourceText) OrElse _
       objectValue.prelude <> "" OrElse _
       InStr(objectValue.typeName, " Ptr") = 0 Then Return 0

    Dim freeFunctionName As String = CBodyCallName( _
        parser.translation[0], parser.catalog[0], "rpl_obstack_free")
    If freeFunctionName = "" Then freeFunctionName = "rpl_obstack_free"

    Dim helperName As String = _
        "c2fb_obstack_free_" & parser.context->functionName
    If InStr(parser.context->generatedBodyHelpers, _
             "Function " & helperName & " ") = 0 Then
        Dim helperText As String
        helperText = "' Reset an obstack object or release its older chunks." & Chr(10)
        helperText &= "Private Function " & helperName & _
            " (ByVal obstack As " & obstackType & " Ptr, " & _
            "ByVal objectValue As Any Ptr) As Any Ptr" & Chr(10)
        helperText &= "    Dim chunkAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->chunk)" & Chr(10)
        helperText &= "    Dim objectAddress As ULongInt = " & _
            "Cast(ULongInt, objectValue)" & Chr(10)
        helperText &= "    Dim chunkLimitAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->chunk_limit)" & Chr(10)
        helperText &= "    If chunkAddress < objectAddress AndAlso " & _
            "objectAddress < chunkLimitAddress Then" & Chr(10)
        helperText &= "        Dim objectPointer As ZString Ptr = " & _
            "CPtr(ZString Ptr, objectAddress)" & Chr(10)
        helperText &= "        obstack->next_free = objectPointer" & Chr(10)
        helperText &= "        obstack->object_base = objectPointer" & Chr(10)
        helperText &= "    Else" & Chr(10)
        helperText &= "        " & freeFunctionName & _
            "(obstack, objectValue)" & Chr(10)
        helperText &= "    End If" & Chr(10)
        helperText &= "    Return Cast(Any Ptr, 0)" & Chr(10)
        helperText &= "End Function"
        parser.context->generatedBodyHelpers &= helperText & Chr(10)
    End If

    value.text = helperName & "(CPtr(" & obstackType & " Ptr, " & _
        pointerValue.text & "), CPtr(Any Ptr, " & objectValue.text & "))"
    value.typeName = "void"
    value.layoutType = "void"
    value.storageType = "void"
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.lValueText = ""
    value.isWholeCall = -1
    value.isFunctionDesignator = 0
    value.isReadOnly = 0
    value.prelude = pointerValue.prelude & objectValue.prelude
    parser.position = endPosition
    parser.hasFunctionCall = -1
    parser.hasRuntimeValue = -1
    Return -1
End Function

Private Function ParseSimpleObstackPointerGrowStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH OrElse parser.context = 0 OrElse _
       parser.translation = 0 OrElse parser.catalog = 0 OrElse _
       parser.translation[0].target.profile <> C2FB_TARGET_GENERIC Then Return 0

    Dim blockContents As String
    Dim endPosition As Long
    If ReadSimpleGnuStatementExpressionBlock( _
        parser.sourceText, extensionPosition, blockContents, endPosition) = 0 Then _
        Return 0
    Dim compactBlock As String = CompactSimpleGnuStatementText(blockContents)
    If Left(compactBlock, Len("structobstack*__o=")) <> _
       "structobstack*__o=" OrElse _
       InStr(compactBlock, "rpl_obstack_newchunk(__o,sizeof(void*))") = 0 OrElse _
       InStr(compactBlock, "*(constvoid**)__p1=") = 0 OrElse _
       InStr(compactBlock, "__o1->next_free+=sizeof(constvoid*)") = 0 OrElse _
       InStr(compactBlock, "(void)0;") = 0 Then Return 0

    Dim pointerStatementEnd As Long = InStr(blockContents, ";")
    If pointerStatementEnd <= 1 Then Return 0
    Dim pointerDeclaration As String = _
        Trim(Left(blockContents, pointerStatementEnd - 1))
    Dim pointerEquals As Long = InStr(pointerDeclaration, "=")
    If pointerEquals <= 1 OrElse _
       CompactSimpleGnuStatementText( _
           Left(pointerDeclaration, pointerEquals - 1)) <> "structobstack*__o" Then _
        Return 0
    Dim obstackArgument As String = _
        Trim(Mid(pointerDeclaration, pointerEquals + 1))
    Dim simpleObjectName As String
    If IsSimpleGnuStatementExpressionAlias( _
        obstackArgument, simpleObjectName) = 0 Then Return 0

    Dim storePosition As Long = InStr(blockContents, "*(const void **)")
    If storePosition = 0 Then Return 0
    Dim storeEquals As Long = InStr(storePosition, blockContents, "=")
    If storeEquals = 0 Then Return 0
    Dim storeEnd As Long = InStr(storeEquals + 1, blockContents, ";")
    If storeEnd <= storeEquals + 1 Then Return 0
    Dim pointerExpression As String = Trim(Mid( _
        blockContents, storeEquals + 1, storeEnd - storeEquals - 1))

    Dim obstackParser As SimpleExpressionParser
    obstackParser.sourceText = obstackArgument
    obstackParser.position = 1
    obstackParser.targetType = "Any Ptr"
    obstackParser.translation = parser.translation
    obstackParser.catalog = parser.catalog
    obstackParser.context = parser.context
    obstackParser.simpleGnuExpressionsNormalized = 0
    obstackParser.hasRuntimeValue = 0
    Dim obstackValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        obstackParser, obstackValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(obstackParser.sourceText, obstackParser.position)
    If obstackParser.position <= Len(obstackParser.sourceText) OrElse _
       obstackValue.prelude <> "" OrElse _
       Right(obstackValue.typeName, 4) <> " Ptr" Then Return 0
    Dim obstackType As String = Left( _
        obstackValue.typeName, Len(obstackValue.typeName) - 4)
    If Left(obstackType, 6) = "Const " OrElse _
       CBodyRecordName( _
           parser.translation[0], parser.catalog[0], obstackType) = "" Then Return 0

    Dim pointerParser As SimpleExpressionParser
    pointerParser.sourceText = pointerExpression
    pointerParser.position = 1
    pointerParser.targetType = "Any Ptr"
    pointerParser.translation = parser.translation
    pointerParser.catalog = parser.catalog
    pointerParser.context = parser.context
    pointerParser.simpleGnuExpressionsNormalized = 0
    pointerParser.hasRuntimeValue = 0
    Dim pointerValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        pointerParser, pointerValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(pointerParser.sourceText, pointerParser.position)
    If pointerParser.position <= Len(pointerParser.sourceText) OrElse _
       pointerValue.prelude <> "" OrElse _
       InStr(pointerValue.typeName, " Ptr") = 0 Then Return 0

    Dim helperName As String = _
        "c2fb_obstack_ptr_grow_" & parser.context->functionName
    If InStr(parser.context->generatedBodyHelpers, _
             "Function " & helperName & " ") = 0 Then
        Dim newChunkName As String = CBodyCallName( _
            parser.translation[0], parser.catalog[0], "rpl_obstack_newchunk")
        If newChunkName = "" Then newChunkName = "rpl_obstack_newchunk"
        Dim helperText As String
        helperText = "' Reserve space before storing one pointer-sized value." & Chr(10)
        helperText &= "Private Function " & helperName & _
            " (ByVal obstack As " & obstackType & " Ptr, " & _
            "ByVal pointerValue As Any Ptr) As Any Ptr" & Chr(10)
        helperText &= "    Dim chunkLimitAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->chunk_limit)" & Chr(10)
        helperText &= "    Dim nextFreeAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->next_free)" & Chr(10)
        helperText &= "    Dim roomBytes As ULongInt = " & _
            "chunkLimitAddress - nextFreeAddress" & Chr(10)
        helperText &= "    Dim pointerBytes As ULongInt = SizeOf(Any Ptr)" & Chr(10)
        helperText &= "    If roomBytes < pointerBytes Then" & Chr(10)
        helperText &= "        " & newChunkName & _
            "(obstack, pointerBytes)" & Chr(10)
        helperText &= "    End If" & Chr(10)
        helperText &= "    Dim pointerSlot As Any Ptr Ptr = " & _
            "CPtr(Any Ptr Ptr, obstack->next_free)" & Chr(10)
        helperText &= "    *pointerSlot = pointerValue" & Chr(10)
        helperText &= "    Dim nextFreeAfterStore As ULongInt = " & _
            "Cast(ULongInt, obstack->next_free)" & Chr(10)
        helperText &= "    obstack->next_free = CPtr(ZString Ptr, " & _
            "nextFreeAfterStore + pointerBytes)" & Chr(10)
        helperText &= "    Return Cast(Any Ptr, 0)" & Chr(10)
        helperText &= "End Function"
        parser.context->generatedBodyHelpers &= helperText & Chr(10)
    End If

    value.text = helperName & "(CPtr(" & obstackType & " Ptr, " & _
        obstackValue.text & "), CPtr(Any Ptr, " & pointerValue.text & "))"
    value.typeName = "void"
    value.layoutType = "void"
    value.storageType = "void"
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.lValueText = ""
    value.isWholeCall = -1
    value.isFunctionDesignator = 0
    value.isReadOnly = 0
    value.prelude = obstackValue.prelude & pointerValue.prelude
    parser.position = endPosition
    parser.hasFunctionCall = -1
    parser.hasRuntimeValue = -1
    Return -1
End Function

Private Function ParseSimpleObstackSingleGrowStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH OrElse parser.context = 0 OrElse _
       parser.translation = 0 OrElse parser.catalog = 0 OrElse _
       parser.translation[0].target.profile <> C2FB_TARGET_GENERIC Then Return 0

    Dim blockContents As String
    Dim endPosition As Long
    If ReadSimpleGnuStatementExpressionBlock( _
        parser.sourceText, extensionPosition, blockContents, endPosition) = 0 Then _
        Return 0
    Dim compactBlock As String = CompactSimpleGnuStatementText(blockContents)
    If Left(compactBlock, Len("structobstack*__o=")) <> _
       "structobstack*__o=" OrElse _
       InStr(compactBlock, "rpl_obstack_newchunk(__o,1)") = 0 OrElse _
       InStr(compactBlock, "(*((__o)->next_free)++=") = 0 OrElse _
       Right(compactBlock, Len("(void)0;")) <> "(void)0;" Then Return 0

    Dim pointerStatementEnd As Long = InStr(blockContents, ";")
    If pointerStatementEnd <= 1 Then Return 0
    Dim pointerDeclaration As String = _
        Trim(Left(blockContents, pointerStatementEnd - 1))
    Dim pointerEquals As Long = InStr(pointerDeclaration, "=")
    If pointerEquals <= 1 OrElse _
       CompactSimpleGnuStatementText( _
           Left(pointerDeclaration, pointerEquals - 1)) <> "structobstack*__o" Then _
        Return 0
    Dim obstackArgument As String = _
        Trim(Mid(pointerDeclaration, pointerEquals + 1))
    Dim simpleObjectName As String
    If IsSimpleGnuStatementExpressionAlias( _
        obstackArgument, simpleObjectName) = 0 Then Return 0

    Dim pointerAdvance As Long = InStr(blockContents, "next_free)++")
    If pointerAdvance = 0 Then Return 0
    Dim datumEquals As Long = InStr(pointerAdvance, blockContents, "=")
    If datumEquals = 0 Then Return 0
    Dim datumEnd As Long = InStr(datumEquals + 1, blockContents, ";")
    If datumEnd <= datumEquals + 1 Then Return 0
    Dim datumExpression As String = Trim(Mid( _
        blockContents, datumEquals + 1, datumEnd - datumEquals - 1))
    ' The fast macro wraps the assignment in an extra pair of parentheses.
    If Right(datumExpression, 1) <> ")" Then Return 0
    datumExpression = Trim(Left(datumExpression, Len(datumExpression) - 1))

    Dim pointerParser As SimpleExpressionParser
    pointerParser.sourceText = obstackArgument
    pointerParser.position = 1
    pointerParser.targetType = "Any Ptr"
    pointerParser.translation = parser.translation
    pointerParser.catalog = parser.catalog
    pointerParser.context = parser.context
    pointerParser.simpleGnuExpressionsNormalized = 0
    pointerParser.hasRuntimeValue = 0
    Dim pointerValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        pointerParser, pointerValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(pointerParser.sourceText, pointerParser.position)
    If pointerParser.position <= Len(pointerParser.sourceText) OrElse _
       pointerValue.prelude <> "" OrElse _
       Right(pointerValue.typeName, 4) <> " Ptr" Then Return 0
    Dim obstackType As String = Left( _
        pointerValue.typeName, Len(pointerValue.typeName) - 4)
    If Left(obstackType, 6) = "Const " OrElse _
       CBodyRecordName( _
           parser.translation[0], parser.catalog[0], obstackType) = "" Then Return 0

    Dim datumParser As SimpleExpressionParser
    datumParser.sourceText = datumExpression
    datumParser.position = 1
    datumParser.targetType = "c2fb_c_int"
    datumParser.translation = parser.translation
    datumParser.catalog = parser.catalog
    datumParser.context = parser.context
    datumParser.simpleGnuExpressionsNormalized = 0
    datumParser.hasRuntimeValue = 0
    Dim datumValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        datumParser, datumValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(datumParser.sourceText, datumParser.position)
    If datumParser.position <= Len(datumParser.sourceText) OrElse _
       datumValue.prelude <> "" OrElse _
       SimpleArithmeticKind(parser.catalog[0], datumValue.typeName) = 0 Then _
        Return 0

    Dim helperName As String = _
        "c2fb_obstack_1grow_" & parser.context->functionName
    If InStr(parser.context->generatedBodyHelpers, _
             "Function " & helperName & " ") = 0 Then
        Dim newChunkName As String = CBodyCallName( _
            parser.translation[0], parser.catalog[0], "rpl_obstack_newchunk")
        If newChunkName = "" Then newChunkName = "rpl_obstack_newchunk"
        Dim helperText As String
        helperText = "' Reserve and append one C char to the current object." & Chr(10)
        helperText &= "Private Function " & helperName & _
            " (ByVal obstack As " & obstackType & " Ptr, " & _
            "ByVal datum As c2fb_c_int) As Any Ptr" & Chr(10)
        helperText &= "    Dim chunkLimitAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->chunk_limit)" & Chr(10)
        helperText &= "    Dim nextFreeAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->next_free)" & Chr(10)
        helperText &= "    If chunkLimitAddress - nextFreeAddress < 1 Then" & Chr(10)
        helperText &= "        " & newChunkName & "(obstack, 1)" & Chr(10)
        helperText &= "    End If" & Chr(10)
        helperText &= "    nextFreeAddress = Cast(ULongInt, obstack->next_free)" & Chr(10)
        helperText &= "    *CPtr(UByte Ptr, nextFreeAddress) = Cast(UByte, datum)" & Chr(10)
        helperText &= "    obstack->next_free = CPtr(ZString Ptr, nextFreeAddress + 1)" & Chr(10)
        helperText &= "    Return Cast(Any Ptr, 0)" & Chr(10)
        helperText &= "End Function"
        parser.context->generatedBodyHelpers &= helperText & Chr(10)
    End If

    value.text = helperName & "(CPtr(" & obstackType & " Ptr, " & _
        pointerValue.text & "), Cast(c2fb_c_int, " & datumValue.text & "))"
    value.typeName = "void"
    value.layoutType = "void"
    value.storageType = "void"
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.lValueText = ""
    value.isWholeCall = -1
    value.isFunctionDesignator = 0
    value.isReadOnly = 0
    value.prelude = pointerValue.prelude & datumValue.prelude
    parser.position = endPosition
    parser.hasFunctionCall = -1
    parser.hasRuntimeValue = -1
    Return -1
End Function

Private Function ParseSimpleObstackFinishStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH OrElse parser.context = 0 OrElse _
       parser.translation = 0 OrElse parser.catalog = 0 OrElse _
       parser.translation[0].target.profile <> C2FB_TARGET_GENERIC Then Return 0

    Dim blockContents As String
    Dim endPosition As Long
    If ReadSimpleGnuStatementExpressionBlock( _
        parser.sourceText, extensionPosition, blockContents, endPosition) = 0 Then _
        Return 0

    Dim compactBlock As String = CompactSimpleGnuStatementText(blockContents)
    Dim firstStatementEnd As Long = InStr(compactBlock, ";")
    If firstStatementEnd <= 1 Then Return 0
    Dim aliasDeclaration As String = Left(compactBlock, firstStatementEnd - 1)
    Const sourceObstackAlias As String = "structobstack*__o1="
    Const canonicalObstackAlias As String = "c2fb_obstack*__o1="
    If Left(aliasDeclaration, Len(sourceObstackAlias)) <> sourceObstackAlias AndAlso _
       Left(aliasDeclaration, Len(canonicalObstackAlias)) <> _
       canonicalObstackAlias Then Return 0

    Const valueDeclaration As String = _
        ";void*__value=(void*)__o1->object_base;"
    Const emptyObjectCheck As String = _
        "if(__o1->next_free==__value)__o1->maybe_empty_object=1;"
    Const objectBaseUpdate As String = _
        ";__o1->object_base=__o1->next_free;__value;"
    If Mid(compactBlock, firstStatementEnd, Len(valueDeclaration)) <> _
       valueDeclaration Then Return 0
    Dim emptyCheckPosition As Long = _
        firstStatementEnd + Len(valueDeclaration)
    If Mid(compactBlock, emptyCheckPosition, Len(emptyObjectCheck)) <> _
       emptyObjectCheck Then Return 0
    Dim alignmentUpdatePosition As Long = _
        emptyCheckPosition + Len(emptyObjectCheck)
    If Mid(compactBlock, alignmentUpdatePosition, _
           Len("__o1->next_free=")) <> "__o1->next_free=" Then Return 0
    Dim objectBaseUpdatePosition As Long = InStr( _
        alignmentUpdatePosition, compactBlock, objectBaseUpdate)
    If objectBaseUpdatePosition <= alignmentUpdatePosition OrElse _
       objectBaseUpdatePosition + Len(objectBaseUpdate) - 1 <> Len(compactBlock) Then _
        Return 0
    Dim alignmentUpdate As String = Mid( _
        compactBlock, alignmentUpdatePosition, _
        objectBaseUpdatePosition - alignmentUpdatePosition)
    Select Case alignmentUpdate
    Case "__o1->next_free=((__o1->next_free)+" & _
         "((-(longunsignedint)(__o1->next_free))&(__o1->alignment_mask)))", _
         "__o1->next_free=((__o1->next_free)+" & _
         "((-(unsignedlongint)(__o1->next_free))&(__o1->alignment_mask)))"
        ' These are the two token orders GCC uses for uintptr_t on the supported
        ' GNU C ABI. Other alignment expressions remain outside this lowering.
    Case Else
        Return 0
    End Select

    Dim initializerEquals As Long = InStr(blockContents, "=")
    If initializerEquals <= 1 Then Return 0
    Dim aliasInitializer As String = Trim(Mid(blockContents, initializerEquals + 1))
    Dim initializerSemicolon As Long = InStr(aliasInitializer, ";")
    If initializerSemicolon <= 1 Then Return 0
    aliasInitializer = Trim(Left(aliasInitializer, initializerSemicolon - 1))

    Dim argumentParser As SimpleExpressionParser
    argumentParser.sourceText = aliasInitializer
    argumentParser.position = 1
    argumentParser.targetType = "Any Ptr"
    argumentParser.translation = parser.translation
    argumentParser.catalog = parser.catalog
    argumentParser.context = parser.context
    argumentParser.simpleGnuExpressionsNormalized = 0
    argumentParser.hasRuntimeValue = 0
    Dim argumentValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        argumentParser, argumentValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(argumentParser.sourceText, argumentParser.position)
    If argumentParser.position <= Len(argumentParser.sourceText) OrElse _
       argumentValue.prelude <> "" OrElse _
       Right(argumentValue.typeName, 4) <> " Ptr" Then Return 0
    Dim obstackType As String = Left( _
        argumentValue.typeName, Len(argumentValue.typeName) - 4)
    If Left(obstackType, 6) = "Const " OrElse _
       CBodyRecordName( _
           parser.translation[0], parser.catalog[0], obstackType) = "" Then Return 0

    Dim helperName As String = _
        "c2fb_obstack_finish_" & parser.context->functionName
    If InStr(parser.context->generatedBodyHelpers, _
             "Function " & helperName & " ") = 0 Then
        Dim helperText As String = _
            "' Keep the C object pointer while advancing the free pointer." & _
            Chr(10) & _
            "' Unsigned negation mirrors obstack.h's uintptr_t alignment." & _
            Chr(10)
        helperText &= "Private Function " & helperName & _
            " (ByVal obstack As " & obstackType & " Ptr) As Any Ptr" & Chr(10)
        helperText &= "    Dim objectValue As Any Ptr = " & _
            "CPtr(Any Ptr, obstack->object_base)" & Chr(10)
        helperText &= "    If obstack->next_free = " & _
            "CPtr(ZString Ptr, objectValue) Then" & Chr(10)
        helperText &= "        obstack->maybe_empty_object = 1" & Chr(10)
        helperText &= "    End If" & Chr(10)
        helperText &= "    Dim nextFreeAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->next_free)" & Chr(10)
        helperText &= "    Dim alignmentMask As ULongInt = " & _
            "obstack->alignment_mask" & Chr(10)
        helperText &= "    Dim unsignedOne As ULongInt = 1" & Chr(10)
        helperText &= "    Dim complementedAddress As ULongInt = " & _
            "Not(nextFreeAddress)" & Chr(10)
        helperText &= "    Dim negativeAddress As ULongInt = " & _
            "complementedAddress + unsignedOne" & Chr(10)
        helperText &= "    Dim alignmentAdjustment As ULongInt = " & _
            "negativeAddress And alignmentMask" & Chr(10)
        helperText &= "    obstack->next_free = CPtr(ZString Ptr, " & _
            "nextFreeAddress + alignmentAdjustment)" & Chr(10)
        helperText &= "    obstack->object_base = obstack->next_free" & Chr(10)
        helperText &= "    Return objectValue" & Chr(10)
        helperText &= "End Function"
        parser.context->generatedBodyHelpers &= _
            helperText & Chr(10)
    End If

    value.text = helperName & "(CPtr(" & obstackType & " Ptr, " & _
        argumentValue.text & "))"
    value.typeName = "Any Ptr"
    value.layoutType = "Any Ptr"
    value.storageType = "Any Ptr"
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.lValueText = ""
    value.isWholeCall = -1
    value.isFunctionDesignator = 0
    value.isReadOnly = 0
    value.prelude = argumentValue.prelude
    parser.position = endPosition
    parser.hasFunctionCall = -1
    parser.hasRuntimeValue = -1
    Return -1
End Function

Private Function ParseSimpleObstackBlankStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH OrElse parser.context = 0 OrElse _
       parser.translation = 0 OrElse parser.catalog = 0 OrElse _
       parser.translation[0].target.profile <> C2FB_TARGET_GENERIC Then Return 0

    Dim blockContents As String
    Dim endPosition As Long
    If ReadSimpleGnuStatementExpressionBlock( _
        parser.sourceText, extensionPosition, blockContents, endPosition) = 0 Then _
        Return 0
    Dim compactBlock As String = CompactSimpleGnuStatementText(blockContents)
    If Left(compactBlock, Len("structobstack*__o=")) <> _
       "structobstack*__o=" OrElse _
       InStr(compactBlock, ";size_t__len=") = 0 OrElse _
       InStr(compactBlock, "chunk_limit") = 0 OrElse _
       InStr(compactBlock, "next_free") = 0 OrElse _
       InStr(compactBlock, "<__len)") = 0 OrElse _
       InStr(compactBlock, "rpl_obstack_newchunk(__o,__len);") = 0 OrElse _
       Right(compactBlock, Len( _
           ";((__o)->next_free+=(__len));(void)0;")) <> _
           ";((__o)->next_free+=(__len));(void)0;" Then Return 0

    Dim pointerStatementEnd As Long = InStr(blockContents, ";")
    If pointerStatementEnd <= 1 Then Return 0
    Dim pointerDeclaration As String = _
        Trim(Left(blockContents, pointerStatementEnd - 1))
    Dim pointerEquals As Long = InStr(pointerDeclaration, "=")
    If pointerEquals <= 1 OrElse _
       CompactSimpleGnuStatementText( _
           Left(pointerDeclaration, pointerEquals - 1)) <> "structobstack*__o" Then _
        Return 0
    Dim obstackArgument As String = _
        Trim(Mid(pointerDeclaration, pointerEquals + 1))
    Dim simpleObjectName As String
    If IsSimpleGnuStatementExpressionAlias( _
        obstackArgument, simpleObjectName) = 0 Then Return 0

    Dim lengthStatementEnd As Long = InStr( _
        pointerStatementEnd + 1, blockContents, ";")
    If lengthStatementEnd <= pointerStatementEnd + 1 Then Return 0
    Dim lengthDeclaration As String = Trim(Mid( _
        blockContents, pointerStatementEnd + 1, _
        lengthStatementEnd - pointerStatementEnd - 1))
    Dim lengthEquals As Long = InStr(lengthDeclaration, "=")
    If lengthEquals <= 1 OrElse _
       CompactSimpleGnuStatementText( _
           Left(lengthDeclaration, lengthEquals - 1)) <> "size_t__len" Then _
        Return 0
    Dim lengthExpression As String = Trim( _
        Mid(lengthDeclaration, lengthEquals + 1))

    Dim pointerParser As SimpleExpressionParser
    pointerParser.sourceText = obstackArgument
    pointerParser.position = 1
    pointerParser.targetType = "Any Ptr"
    pointerParser.translation = parser.translation
    pointerParser.catalog = parser.catalog
    pointerParser.context = parser.context
    pointerParser.simpleGnuExpressionsNormalized = 0
    pointerParser.hasRuntimeValue = 0
    Dim pointerValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        pointerParser, pointerValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(pointerParser.sourceText, pointerParser.position)
    If pointerParser.position <= Len(pointerParser.sourceText) OrElse _
       pointerValue.prelude <> "" OrElse _
       Right(pointerValue.typeName, 4) <> " Ptr" Then Return 0
    Dim obstackType As String = Left( _
        pointerValue.typeName, Len(pointerValue.typeName) - 4)
    If Left(obstackType, 6) = "Const " OrElse _
       CBodyRecordName( _
           parser.translation[0], parser.catalog[0], obstackType) = "" Then Return 0

    Dim lengthParser As SimpleExpressionParser
    lengthParser.sourceText = lengthExpression
    lengthParser.position = 1
    lengthParser.targetType = "c2fb_size_t"
    lengthParser.translation = parser.translation
    lengthParser.catalog = parser.catalog
    lengthParser.context = parser.context
    lengthParser.simpleGnuExpressionsNormalized = 0
    lengthParser.hasRuntimeValue = 0
    Dim lengthValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        lengthParser, lengthValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(lengthParser.sourceText, lengthParser.position)
    If lengthParser.position <= Len(lengthParser.sourceText) OrElse _
       lengthValue.prelude <> "" OrElse _
       SimpleArithmeticKind(parser.catalog[0], lengthValue.typeName) = 0 Then _
        Return 0

    Dim helperName As String = _
        "c2fb_obstack_blank_" & parser.context->functionName
    If InStr(parser.context->generatedBodyHelpers, _
             "Function " & helperName & " ") = 0 Then
        Dim newChunkName As String = CBodyCallName( _
            parser.translation[0], parser.catalog[0], "rpl_obstack_newchunk")
        If newChunkName = "" Then newChunkName = "rpl_obstack_newchunk"
        Dim helperText As String
        helperText = "' Reserve obstack space before advancing its free pointer." & Chr(10)
        helperText &= "Private Function " & helperName & _
            " (ByVal obstack As " & obstackType & " Ptr, " & _
            "ByVal byteCount As c2fb_size_t) As Any Ptr" & Chr(10)
        helperText &= "    Dim chunkLimitAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->chunk_limit)" & Chr(10)
        helperText &= "    Dim nextFreeAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->next_free)" & Chr(10)
        helperText &= "    Dim roomBytes As ULongInt = " & _
            "chunkLimitAddress - nextFreeAddress" & Chr(10)
        helperText &= "    Dim lengthAsAddress As ULongInt = byteCount" & Chr(10)
        helperText &= "    If roomBytes < lengthAsAddress Then" & Chr(10)
        helperText &= "        " & newChunkName & _
            "(obstack, byteCount)" & Chr(10)
        helperText &= "    End If" & Chr(10)
        helperText &= "    Dim nextFreeAfterChunk As ULongInt = " & _
            "Cast(ULongInt, obstack->next_free)" & Chr(10)
        helperText &= "    nextFreeAfterChunk = nextFreeAfterChunk + " & _
            "lengthAsAddress" & Chr(10)
        helperText &= "    obstack->next_free = CPtr(ZString Ptr, " & _
            "nextFreeAfterChunk)" & Chr(10)
        helperText &= "    Return Cast(Any Ptr, 0)" & Chr(10)
        helperText &= "End Function"
        parser.context->generatedBodyHelpers &= helperText & Chr(10)
    End If

    value.text = helperName & "(CPtr(" & obstackType & " Ptr, " & _
        pointerValue.text & "), Cast(c2fb_size_t, " & lengthValue.text & "))"
    value.typeName = "void"
    value.layoutType = "void"
    value.storageType = "void"
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.lValueText = ""
    value.isWholeCall = -1
    value.isFunctionDesignator = 0
    value.isReadOnly = 0
    value.prelude = ""
    parser.position = endPosition
    parser.hasFunctionCall = -1
    parser.hasRuntimeValue = -1
    Return -1
End Function

Private Function ParseSimpleObstackGrowStatementExpression( _
    ByRef parser As SimpleExpressionParser, _
    ByRef value As SimpleExpressionValue, _
    ByVal extensionPosition As Long, _
    ByVal depth As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long _
) As Long
    If depth > MAX_EXPRESSION_DEPTH OrElse parser.context = 0 OrElse _
       parser.translation = 0 OrElse parser.catalog = 0 OrElse _
       parser.translation[0].target.profile <> C2FB_TARGET_GENERIC Then Return 0

    Dim blockContents As String
    Dim endPosition As Long
    If ReadSimpleGnuStatementExpressionBlock( _
        parser.sourceText, extensionPosition, blockContents, endPosition) = 0 Then _
        Return 0
    Dim compactBlock As String = CompactSimpleGnuStatementText(blockContents)
    If Left(compactBlock, Len("structobstack*__o=")) <> _
       "structobstack*__o=" OrElse _
       InStr(compactBlock, ";size_t__len=") = 0 OrElse _
       InStr(compactBlock, "chunk_limit") = 0 OrElse _
       InStr(compactBlock, "next_free") = 0 OrElse _
       InStr(compactBlock, "<__len)") = 0 OrElse _
       InStr(compactBlock, "rpl_obstack_newchunk(__o,__len);") = 0 OrElse _
       InStr(compactBlock, "memcpy(__o->next_free,") = 0 OrElse _
       Right(compactBlock, Len( _
           ";__o->next_free+=__len;(void)0;")) <> _
           ";__o->next_free+=__len;(void)0;" Then Return 0

    Dim pointerStatementEnd As Long = InStr(blockContents, ";")
    If pointerStatementEnd <= 1 Then Return 0
    Dim pointerDeclaration As String = _
        Trim(Left(blockContents, pointerStatementEnd - 1))
    Dim pointerEquals As Long = InStr(pointerDeclaration, "=")
    If pointerEquals <= 1 OrElse _
       CompactSimpleGnuStatementText( _
           Left(pointerDeclaration, pointerEquals - 1)) <> "structobstack*__o" Then _
        Return 0
    Dim obstackArgument As String = _
        Trim(Mid(pointerDeclaration, pointerEquals + 1))
    Dim simpleObjectName As String
    If IsSimpleGnuStatementExpressionAlias( _
        obstackArgument, simpleObjectName) = 0 Then Return 0

    Dim lengthStatementEnd As Long = InStr( _
        pointerStatementEnd + 1, blockContents, ";")
    If lengthStatementEnd <= pointerStatementEnd + 1 Then Return 0
    Dim lengthDeclaration As String = Trim(Mid( _
        blockContents, pointerStatementEnd + 1, _
        lengthStatementEnd - pointerStatementEnd - 1))
    Dim lengthEquals As Long = InStr(lengthDeclaration, "=")
    If lengthEquals <= 1 OrElse _
       CompactSimpleGnuStatementText( _
           Left(lengthDeclaration, lengthEquals - 1)) <> "size_t__len" Then _
        Return 0
    Dim lengthExpression As String = Trim( _
        Mid(lengthDeclaration, lengthEquals + 1))

    Dim memcpyPosition As Long = InStr(blockContents, "memcpy")
    If memcpyPosition <= lengthStatementEnd Then Return 0
    Dim memcpyOpen As Long = InStr(memcpyPosition, blockContents, "(")
    If memcpyOpen = 0 Then Return 0
    Dim memcpyEnd As Long = memcpyOpen
    If ScanSimpleExpressionGroup( _
        blockContents, memcpyEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim memcpyArguments() As String
    Dim memcpyArgumentCount As Long
    Dim memcpyArgumentText As String = Mid( _
        blockContents, memcpyOpen + 1, memcpyEnd - memcpyOpen - 2)
    If SplitSimpleCList( _
        memcpyArgumentText, memcpyArguments(), memcpyArgumentCount) = 0 OrElse _
       memcpyArgumentCount <> 3 OrElse _
       CompactSimpleGnuStatementText(memcpyArguments(0)) <> _
           "__o->next_free" Then Return 0
    Dim sourceExpression As String = Trim(memcpyArguments(1))
    Dim sourceAddress As String
    If IsSimpleGnuStatementExpressionAlias( _
        sourceExpression, sourceAddress) = 0 OrElse _
       Left(Trim(sourceExpression), 1) <> "&" Then Return 0
    If Trim(memcpyArguments(2)) <> "__len" Then Return 0

    Dim pointerParser As SimpleExpressionParser
    pointerParser.sourceText = obstackArgument
    pointerParser.position = 1
    pointerParser.targetType = "Any Ptr"
    pointerParser.translation = parser.translation
    pointerParser.catalog = parser.catalog
    pointerParser.context = parser.context
    pointerParser.simpleGnuExpressionsNormalized = 0
    pointerParser.hasRuntimeValue = 0
    Dim pointerValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        pointerParser, pointerValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(pointerParser.sourceText, pointerParser.position)
    If pointerParser.position <= Len(pointerParser.sourceText) OrElse _
       pointerValue.prelude <> "" OrElse _
       Right(pointerValue.typeName, 4) <> " Ptr" Then Return 0
    Dim obstackType As String = Left( _
        pointerValue.typeName, Len(pointerValue.typeName) - 4)
    If Left(obstackType, 6) = "Const " OrElse _
       CBodyRecordName( _
           parser.translation[0], parser.catalog[0], obstackType) = "" Then Return 0

    Dim sourceParser As SimpleExpressionParser
    sourceParser.sourceText = sourceExpression
    sourceParser.position = 1
    sourceParser.targetType = "Any Ptr"
    sourceParser.translation = parser.translation
    sourceParser.catalog = parser.catalog
    sourceParser.context = parser.context
    sourceParser.simpleGnuExpressionsNormalized = 0
    sourceParser.hasRuntimeValue = 0
    Dim sourceValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        sourceParser, sourceValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(sourceParser.sourceText, sourceParser.position)
    If sourceParser.position <= Len(sourceParser.sourceText) OrElse _
       sourceValue.prelude <> "" OrElse _
       InStr(sourceValue.typeName, " Ptr") = 0 Then Return 0

    Dim lengthParser As SimpleExpressionParser
    lengthParser.sourceText = lengthExpression
    lengthParser.position = 1
    lengthParser.targetType = "c2fb_size_t"
    lengthParser.translation = parser.translation
    lengthParser.catalog = parser.catalog
    lengthParser.context = parser.context
    lengthParser.simpleGnuExpressionsNormalized = 0
    lengthParser.hasRuntimeValue = 0
    Dim lengthValue As SimpleExpressionValue
    If ParseSimpleExpressionValue( _
        lengthParser, lengthValue, 1, depth + 1, callableNames(), _
        callableCount, parameterNames(), parameterAliases(), parameterTypes(), _
        parameterCount) = 0 Then Return 0
    SkipCSpaces(lengthParser.sourceText, lengthParser.position)
    If lengthParser.position <= Len(lengthParser.sourceText) OrElse _
       lengthValue.prelude <> "" OrElse _
       SimpleArithmeticKind(parser.catalog[0], lengthValue.typeName) = 0 Then _
        Return 0

    Dim helperName As String = _
        "c2fb_obstack_grow_" & parser.context->functionName
    If InStr(parser.context->generatedBodyHelpers, _
             "Function " & helperName & " ") = 0 Then
        Dim newChunkName As String = CBodyCallName( _
            parser.translation[0], parser.catalog[0], "rpl_obstack_newchunk")
        If newChunkName = "" Then newChunkName = "rpl_obstack_newchunk"
        Dim memcpyName As String = CBodyCallName( _
            parser.translation[0], parser.catalog[0], "memcpy")
        If memcpyName = "" Then memcpyName = "memcpy"
        Dim helperText As String
        helperText = "' Reserve obstack space before copying and advancing." & Chr(10)
        helperText &= "Private Function " & helperName & _
            " (ByVal obstack As " & obstackType & " Ptr, " & _
            "ByVal source As Any Ptr, ByVal byteCount As c2fb_size_t) " & _
            "As Any Ptr" & Chr(10)
        helperText &= "    Dim chunkLimitAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->chunk_limit)" & Chr(10)
        helperText &= "    Dim nextFreeAddress As ULongInt = " & _
            "Cast(ULongInt, obstack->next_free)" & Chr(10)
        helperText &= "    Dim roomBytes As ULongInt = " & _
            "chunkLimitAddress - nextFreeAddress" & Chr(10)
        helperText &= "    Dim lengthAsAddress As ULongInt = byteCount" & Chr(10)
        helperText &= "    If roomBytes < lengthAsAddress Then" & Chr(10)
        helperText &= "        " & newChunkName & _
            "(obstack, byteCount)" & Chr(10)
        helperText &= "    End If" & Chr(10)
        helperText &= "    " & memcpyName & "(" & _
            "CPtr(Any Ptr, obstack->next_free), source, byteCount)" & Chr(10)
        helperText &= "    Dim nextFreeAfterCopy As ULongInt = " & _
            "Cast(ULongInt, obstack->next_free)" & Chr(10)
        helperText &= "    nextFreeAfterCopy = nextFreeAfterCopy + " & _
            "lengthAsAddress" & Chr(10)
        helperText &= "    obstack->next_free = CPtr(ZString Ptr, " & _
            "nextFreeAfterCopy)" & Chr(10)
        helperText &= "    Return Cast(Any Ptr, 0)" & Chr(10)
        helperText &= "End Function"
        parser.context->generatedBodyHelpers &= helperText & Chr(10)
    End If

    value.text = helperName & "(CPtr(" & obstackType & " Ptr, " & _
        pointerValue.text & "), CPtr(Any Ptr, " & sourceValue.text & "), " & _
        "Cast(c2fb_size_t, " & lengthValue.text & "))"
    value.typeName = "void"
    value.layoutType = "void"
    value.storageType = "void"
    value.cRecord = ""
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.lValueText = ""
    value.isWholeCall = -1
    value.isFunctionDesignator = 0
    value.isReadOnly = 0
    value.prelude = ""
    parser.position = endPosition
    parser.hasFunctionCall = -1
    parser.hasRuntimeValue = -1
    Return -1
End Function

Private Function SimpleBooleanConversionExpression( _
    ByVal expressionText As String _
) As String
    ' C _Bool stores exactly 0 or 1, including pointer conversions.
    Return "IIf((" & expressionText & ") <> 0, 1, 0)"
End Function

Private Function TranslateSimpleExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal inputExpression As String, _
    ByRef outputExpression As String, _
    ByRef hasBooleanOperator As Long, _
    ByRef hasFunctionCall As Long, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long, _
    ByVal targetType As String, _
    ByVal allowBodyReplacements As Long = -1, _
    ByVal requireConstant As Long = 0, _
    ByVal targetIsBoolean As Long = 0 _
) As Long
    outputExpression = ""
    hasBooleanOperator = 0
    hasFunctionCall = 0
    Dim normalizedExpression As String
    If StripGnulibCountofArrayTypeCheck( _
        inputExpression, normalizedExpression) <> 0 Then _
        inputExpression = normalizedExpression
    If translation.target.profile <> C2FB_TARGET_SQLITE AndAlso allowBodyReplacements <> 0 Then
        Dim replacementText As String
        Dim toFreeBasic As Long
        If C2fbReplacementRuleMatch( _
            translation.genericC.policy, inputExpression, replacementText, toFreeBasic) <> 0 Then
            If toFreeBasic <> 0 Then
                If requireConstant <> 0 Then Return 0
                If C2fbReplacementRuleHasMultipleLines( _
                    translation.genericC.policy, inputExpression) <> 0 Then Return 0
                outputExpression = RewriteGenericBodyLocalNames( _
                    replacementText, parameterNames(), parameterAliases(), parameterCount)
                If targetIsBoolean <> 0 Then _
                    outputExpression = SimpleBooleanConversionExpression(outputExpression)
                hasFunctionCall = CInt(InStr(replacementText, "(") <> 0)
                Return -1
            End If
            Dim commentDepth As Long = 0
            replacementText = StripComments(replacementText, commentDepth)
            Return TranslateSimpleExpression( _
                translation, catalog, replacementText, outputExpression, hasBooleanOperator, _
                hasFunctionCall, callableNames(), callableCount, _
                parameterNames(), parameterAliases(), parameterTypes(), _
                parameterCount, targetType, 0, requireConstant, targetIsBoolean)
        End If
    End If
    Dim parser As SimpleExpressionParser
    parser.sourceText = inputExpression
    parser.position = 1
    parser.targetType = targetType
    parser.translation = @translation
    parser.catalog = @catalog
    parser.hasRuntimeValue = 0
    Dim value As SimpleExpressionValue
    If ParseSimpleExpressionValue(parser, value, 1, 0, callableNames(), callableCount, _
                                  parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position <= Len(parser.sourceText) OrElse value.prelude <> "" OrElse _
       value.typeName = "void" OrElse _
       (requireConstant <> 0 AndAlso _
        (parser.hasRuntimeValue <> 0 OrElse parser.hasFunctionCall <> 0)) Then Return 0
    outputExpression = value.text
    If targetIsBoolean <> 0 Then _
        outputExpression = SimpleBooleanConversionExpression(outputExpression)
    If requireConstant = 0 AndAlso _
       NormalizeFbBodyType(catalog, targetType) = "CLongDouble" AndAlso _
       NormalizeFbBodyType(catalog, value.typeName) <> "CLongDouble" Then
        ' C aggregate members need the same explicit ABI-carrier conversion as
        ' scalar declarations when their initializer has an integer type.
        outputExpression = SimpleValueCast( _
            translation, catalog, value, targetType)
        If outputExpression = "" Then Return 0
    End If
    Dim targetKind As Long = SimpleArithmeticKind(parser.catalog[0], targetType)
    If SimpleArithmeticKindIsInteger(targetKind) <> 0 AndAlso _
       SimpleFloatingCastNeedsFix( _
           SimpleArithmeticKind(parser.catalog[0], value.typeName)) <> 0 Then
        outputExpression = "Cast(" & targetType & ", Fix(" & outputExpression & "))"
    End If
    hasBooleanOperator = parser.hasBooleanOperator
    hasFunctionCall = parser.hasFunctionCall
    Return -1
End Function

Private Function TranslateSequencedExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal inputExpression As String, ByRef outputExpression As String, _
    ByRef expressionPrelude As String, ByRef context As SimpleBodyContext, _
    callableNames() As String, ByVal callableCount As Long, _
    parameterNames() As String, parameterAliases() As String, _
    parameterTypes() As String, ByVal parameterCount As Long, _
    ByVal targetType As String = "", _
    ByVal targetIsBoolean As Long = 0 _
) As Long
    outputExpression = ""
    expressionPrelude = ""
    Dim sourceExpression As String = inputExpression
    Dim normalizedExpression As String
    If StripGnulibCountofArrayTypeCheck( _
        sourceExpression, normalizedExpression) <> 0 Then _
        sourceExpression = normalizedExpression
    If translation.target.profile <> C2FB_TARGET_SQLITE Then
        Dim replacementText As String
        Dim toFreeBasic As Long
        If C2fbReplacementRuleMatch( _
            translation.genericC.policy, sourceExpression, replacementText, toFreeBasic) <> 0 Then
            If toFreeBasic <> 0 Then
                If C2fbReplacementRuleHasMultipleLines( _
                    translation.genericC.policy, inputExpression) <> 0 Then Return 0
                outputExpression = RewriteGenericBodyLocalNames( _
                    replacementText, parameterNames(), parameterAliases(), parameterCount)
                If targetIsBoolean <> 0 Then _
                    outputExpression = SimpleBooleanConversionExpression(outputExpression)
                Return -1
            End If
            Dim commentDepth As Long = 0
            sourceExpression = StripComments(replacementText, commentDepth)
        End If
    End If
    Dim parser As SimpleExpressionParser
    parser.sourceText = sourceExpression
    parser.position = 1
    parser.targetType = targetType
    parser.translation = @translation
    parser.catalog = @catalog
    parser.context = @context
    parser.hasRuntimeValue = 0
    Dim value As SimpleExpressionValue
    If ParseSimpleExpressionValue(parser, value, 1, 0, callableNames(), callableCount, _
                                  parameterNames(), parameterAliases(), parameterTypes(), parameterCount) = 0 Then
        RecordSimpleBodyFailure( _
            context, "unsupported-expression", _
            "expression parser stopped at byte " & Trim(Str(parser.position)) & _
            " in (" & Left(parser.sourceText, 120) & "): " & _
            Left(Mid(parser.sourceText, parser.position), 80))
        Return 0
    End If
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position <= Len(parser.sourceText) OrElse value.typeName = "void" Then
        RecordSimpleBodyFailure( _
            context, "unsupported-expression-suffix", _
            "expression parser left an unsupported suffix: " & _
            Left(Mid(parser.sourceText, parser.position), 80))
        Return 0
    End If
    outputExpression = value.text
    If targetIsBoolean <> 0 Then _
        outputExpression = SimpleBooleanConversionExpression(outputExpression)
    If NormalizeFbBodyType(catalog, targetType) = "CLongDouble" AndAlso _
       NormalizeFbBodyType(catalog, value.typeName) <> "CLongDouble" Then
        ' C permits arithmetic values to initialize a long double object. The
        ' FreeBASIC ABI carrier is byte-backed, so make the conversion explicit.
        outputExpression = SimpleValueCast( _
            translation, catalog, value, targetType)
        If outputExpression = "" Then Return 0
    End If
    Dim targetPointeeType As String = SimplePointeeType(targetType)
    Dim valuePointeeType As String = SimplePointeeType(value.typeName)
    Dim targetHasConstPointee As Long = CInt(Left(targetType, 6) = "Const ")
    Dim valueHasConstPointee As Long = CInt(Left(value.typeName, 6) = "Const ")
    If targetPointeeType <> "" AndAlso _
       targetPointeeType = valuePointeeType AndAlso _
       valueHasConstPointee <> 0 AndAlso targetHasConstPointee = 0 Then Return 0
    If targetPointeeType <> "" AndAlso _
       targetPointeeType = valuePointeeType AndAlso _
       targetType <> value.typeName AndAlso _
       (valueHasConstPointee = 0 OrElse targetHasConstPointee <> 0) Then
        ' C char arrays decay to byte pointers, while the public FreeBASIC
        ' ABI represents char* as ZString Ptr. Keep that same-address pointer
        ' conversion explicit when a body returns an array expression.
        outputExpression = "CPtr(" & targetType & ", " & outputExpression & ")"
    End If
    If targetType <> value.typeName AndAlso _
       InStr(targetType, " Ptr") <> 0 AndAlso _
       InStr(value.typeName, " Ptr") <> 0 AndAlso _
       IsCBodyCallbackTypeInContext(translation, targetType) = 0 AndAlso _
       IsCBodyCallbackTypeInContext(translation, value.typeName) = 0 Then
        ' C permits object-pointer conversions that FreeBASIC requires CPtr for.
        outputExpression = "CPtr(" & targetType & ", " & outputExpression & ")"
    End If
    Dim targetKind As Long = SimpleArithmeticKind(parser.catalog[0], targetType)
    If SimpleArithmeticKindIsInteger(targetKind) <> 0 AndAlso _
       SimpleFloatingCastNeedsFix( _
           SimpleArithmeticKind(parser.catalog[0], value.typeName)) <> 0 Then
        outputExpression = "Cast(" & targetType & ", Fix(" & outputExpression & "))"
    End If
    expressionPrelude = value.prelude
    Return -1
End Function

/' end of c2fb_expr.bi '/
