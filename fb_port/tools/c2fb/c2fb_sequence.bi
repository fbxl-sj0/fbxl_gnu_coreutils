/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_sequence.bi

    Purpose:

        Lower C expression side effects to ordered FreeBASIC statements.

    Responsibilities:

        - Allocate scalar temporaries within the current procedure.
        - Evaluate an updated storage address once.
        - Capture containing records before writing direct bitfield members.
        - Preserve assignment values and prefix/postfix increment values.
        - Normalize pointer aliases before converting callback assignments.
        - Keep discarded expression evaluation at its C sequence point.
        - Create initialized storage for function-scoped alloca cleanup.

    This file intentionally does NOT contain:

        - Token scanning, statement control flow, or runtime helpers.
'/

' These declarations live with the other hoisted automatic storage. A bound
' prevents a pathological expression from exhausting the generated procedure.
Private Const MAX_EXPRESSION_TEMPORARIES As Long = 4096

Private Function NewSimpleBodyTemporary( _
    ByRef context As SimpleBodyContext, ByVal typeName As String, _
    ByVal initialValue As String _
) As String
    If typeName = "" Then Return ""
    If context.temporarySerial >= MAX_EXPRESSION_TEMPORARIES Then Return ""
    Dim result As String = "c2fb_temp_" & Trim(Str(context.temporarySerial))
    context.temporarySerial += 1
    context.declarations &= "    Dim " & result & " As " & typeName
    If initialValue <> "" Then context.declarations &= " = " & initialValue
    context.declarations &= Chr(10)
    Return result
End Function

Private Function NewSimpleTemporary( _
    ByRef parser As SimpleExpressionParser, ByVal typeName As String _
) As String
    If parser.context = 0 OrElse typeName = "" OrElse typeName = "void" Then Return ""
    Return NewSimpleBodyTemporary(parser.context[0], typeName, "")
End Function

Private Function EnsureSimpleAllocaTracking( _
    ByRef context As SimpleBodyContext _
) As Long
    If context.allocaHeadName <> "" OrElse context.allocaNextName <> "" Then _
        Return CInt(context.allocaHeadName <> "" AndAlso context.allocaNextName <> "") * -1
    Dim headName As String = NewSimpleBodyTemporary(context, "Any Ptr", "0")
    Dim nextName As String = NewSimpleBodyTemporary(context, "Any Ptr", "")
    If headName = "" OrElse nextName = "" Then Return 0
    context.allocaHeadName = headName
    context.allocaNextName = nextName
    Return -1
End Function

Private Function SimpleConvertedValue( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef value As SimpleExpressionValue, ByVal targetType As String _
) As String
    Dim normalizedTargetType As String = NormalizeFbBodyType(catalog, targetType)
    Dim halfFloatText As String = SimpleHalfFloatValueText( _
        translation, catalog, value, normalizedTargetType)
    If halfFloatText <> "" Then Return halfFloatText
    If NormalizeFbBodyType(catalog, value.typeName) = normalizedTargetType Then _
        Return value.text
    If InStr(normalizedTargetType, " Ptr") <> 0 OrElse _
       IsCBodyCallbackTypeInContext(translation, normalizedTargetType) <> 0 Then
        Return SimpleValueCast( _
            translation, catalog, value, normalizedTargetType)
    End If
    Dim targetKind As Long = SimpleArithmeticKind(catalog, normalizedTargetType)
    If targetKind = 0 Then
        ' A known C aggregate may be copied through its existing BASIC record.
        ' Its layout remains the port's responsibility, as for its other uses.
        If NormalizeFbBodyType(catalog, value.typeName) = _
           normalizedTargetType AndAlso _
           CBodyRecordName(translation, catalog, normalizedTargetType) <> "" Then _
            Return value.text
        Return ""
    End If
    Dim sourceKind As Long = SimpleArithmeticKind(catalog, value.typeName)
    If targetKind = 7 OrElse sourceKind = 7 Then
        Return SimpleValueCast(translation, catalog, value, normalizedTargetType)
    End If
    Dim sourceText As String = value.text
    If targetKind <= 4 AndAlso SimpleFloatingCastNeedsFix(sourceKind) <> 0 Then _
        sourceText = "Fix(" & sourceText & ")"
    Return "Cast(" & normalizedTargetType & ", " & sourceText & ")"
End Function

Private Function FreezeSimpleValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue _
) As Long
    Dim temporary As String = NewSimpleTemporary(parser, value.typeName)
    If temporary = "" Then Return 0
    value.prelude &= temporary & " = " & value.text & Chr(10)
    value.text = temporary
    value.isLValue = 0
    value.lValueText = ""
    value.isWholeCall = 0
    value.isFunctionDesignator = 0
    value.arrayCount = 0
    value.arrayBound = ""
    Return -1
End Function

Private Function DiscardSimpleValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue _
) As Long
    If value.text = "" Then Return -1
    If value.typeName = "void" AndAlso value.isWholeCall = 0 Then
        ' A parenthesized (void) expression may have placeholder text after
        ' grouping. Its effects already live in prelude and it has no value to
        ' freeze into an automatic temporary.
        value.text = ""
        Return -1
    End If
    If Left(value.text, 10) = "c2fb_temp_" AndAlso IsIdentifierToken(value.text) <> 0 Then
        ' The prelude already computed this value, and the temporary is not
        ' volatile. Discarding it requires no additional evaluation.
    ElseIf value.isWholeCall <> 0 Then
        Dim discardedText As String = value.text
        If value.typeName = "void" Then
            ' FreeBASIC does not allow a Sub call to be grouped as an
            ' expression. C permits those parentheses around a void call.
            While Len(discardedText) >= 2 AndAlso _
                  Left(discardedText, 1) = "("
                Dim groupEnd As Long = 1
                If ScanSimpleExpressionGroup( _
                    discardedText, groupEnd, Asc("("), Asc(")")) = 0 OrElse _
                   groupEnd <> Len(discardedText) + 1 Then Exit While
                discardedText = Trim(Mid( _
                    discardedText, 2, Len(discardedText) - 2))
            Wend
        End If
        value.prelude &= discardedText & Chr(10)
    Else
        If FreezeSimpleValue(parser, value) = 0 Then Return 0
    End If
    value.text = ""
    Return -1
End Function

Private Function CaptureSimpleStorage( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue, _
    ByRef storage As String _
) As Long
    If value.isLValue = 0 OrElse value.isReadOnly <> 0 OrElse value.arrayBound <> "" OrElse _
       (value.bitWidth >= 0 AndAlso value.isDirectBitField = 0 AndAlso _
        value.isPackedBitField = 0) OrElse _
       value.typeName = "" Then Return 0
    If value.isDirectBitField <> 0 Then
        If parser.context = 0 OrElse value.bitFieldOwnerText = "" OrElse _
           value.bitFieldOwnerType = "" OrElse value.bitFieldName = "" Then Return 0
        Dim ownerAddress As String = value.bitFieldOwnerText
        If value.bitFieldOwnerIsPointer = 0 Then _
            ownerAddress = "@(" & ownerAddress & ")"
        Dim ownerPointer As String = NewSimpleTemporary( _
            parser, value.bitFieldOwnerType & " Ptr")
        If ownerPointer = "" Then Return 0
        value.prelude &= ownerPointer & " = CPtr(" & _
            value.bitFieldOwnerType & " Ptr, " & ownerAddress & ")" & Chr(10)
        storage = ownerPointer & "->" & value.bitFieldName
        value.text = storage
        If value.isSignedBitField <> 0 Then
            value.text = SimpleBitFieldValueText( _
                value.typeName, storage, value.bitWidth, 0, _
                C2FB_BITFIELD_SIGNEDNESS_SIGNED)
            If value.text = "" Then Return 0
        End If
        Return -1
    End If
    If value.isPackedBitField <> 0 Then
        storage = value.bitStorageText
    Else
        storage = value.text
        If value.lValueText <> "" Then storage = value.lValueText
    End If
    ' A direct variable already identifies its storage without evaluation.
    If IsIdentifierToken(storage) <> 0 Then Return -1
    Dim storageType As String = value.storageType
    If storageType = "" Then storageType = value.typeName
    ' An inline procedure-pointer type cannot be suffixed with another Ptr:
    ' that would change its return type. A local type alias names the procedure
    ' pointer itself, allowing a pointer to the callback's storage.
    If IsCBodyCallbackTypeInContext(parser.translation[0], storageType) <> 0 Then
        If parser.context = 0 Then Return 0
        Dim aliasName As String = "c2fb_callback_storage_" & Trim(Str(parser.context->temporarySerial))
        parser.context->declarations &= "    Type " & aliasName & " As " & storageType & Chr(10)
        storageType = aliasName
    End If
    Dim addressName As String = NewSimpleTemporary(parser, storageType & " Ptr")
    If addressName = "" Then Return 0
    ' C may qualify the data behind a pointer without making the pointer slot
    ' itself read-only. Use the port field's declared storage type for its
    ' address so writes through const-qualified pointer views retain the C
    ' distinction between pointer storage and pointed-to data.
    value.prelude &= addressName & " = CPtr(" & storageType & " Ptr, @(" & _
        storage & "))" & Chr(10)
    storage = "(*" & addressName & ")"
    ' Port fields can use narrower storage than the promoted C field type.
    ' Read through the actual storage type, then apply the C value conversion.
    value.text = storage
    If value.typeName <> storageType Then _
        value.text = SimpleConvertedValue( _
            parser.translation[0], parser.catalog[0], value, value.typeName)
    If value.isPackedBitField <> 0 Then
        Dim bitfieldSignedness As Long = IIf( _
            value.isSignedBitField <> 0, _
            C2FB_BITFIELD_SIGNEDNESS_SIGNED, _
            C2FB_BITFIELD_SIGNEDNESS_UNSIGNED)
        value.text = SimpleBitFieldValueText( _
            value.typeName, storage, value.bitWidth, value.bitOffset, _
            bitfieldSignedness)
        If value.text = "" Then Return 0
    End If
    Return -1
End Function

Private Function ApplySimpleIncrement( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue, _
    ByVal isDecrement As Long, ByVal isPostfix As Long _
) As Long
    If parser.unevaluated <> 0 Then
        If value.isLValue = 0 Then Return 0
        value.isLValue = 0
        Return -1
    End If
    Dim isDirectBitField As Long = value.isDirectBitField
    Dim isPackedBitField As Long = value.isPackedBitField
    Dim isSignedBitField As Long = value.isSignedBitField
    Dim isUnsignedBitField As Long = value.isUnsignedBitField
    Dim bitWidth As Long = value.bitWidth
    Dim bitOffset As Long = value.bitOffset
    Dim storageType As String = value.storageType
    Dim storage As String
    If CaptureSimpleStorage(parser, value, storage) = 0 Then Return 0
    If SimpleArithmeticKind(parser.catalog[0], value.typeName) = 0 AndAlso _
       (SimplePointeeType(value.typeName) = "" OrElse SimplePointeeType(value.typeName) = "Any") Then Return 0
    Dim oldValue As SimpleExpressionValue = value
    If FreezeSimpleValue(parser, oldValue) = 0 Then Return 0
    Dim stepOperator As String = IIf(isDecrement <> 0, " - ", " + ")
    Dim promotedType As String = SimpleArithmeticType( _
        SimpleArithmeticKind(parser.catalog[0], value.typeName))
    Dim newValue As SimpleExpressionValue
    newValue.typeName = value.typeName
    If promotedType <> "" Then
        newValue.text = "Cast(" & promotedType & ", (" & _
            SimpleValueCast(parser.translation[0], parser.catalog[0], oldValue, promotedType) & _
            stepOperator & "1))"
        newValue.text = SimpleConvertedValue( _
            parser.translation[0], parser.catalog[0], newValue, value.typeName)
    Else
        newValue.text = "(" & oldValue.text & stepOperator & "1)"
    End If
    Dim valueForStorage As String = newValue.text
    Dim valueAfterStorage As String = storage
    If isDirectBitField <> 0 OrElse isPackedBitField <> 0 Then
        If SimpleBitFieldStoredValues( _
            parser, value.typeName, storageType, isPackedBitField, _
            isSignedBitField, isUnsignedBitField, bitWidth, bitOffset, _
            storage, newValue.text, valueForStorage, valueAfterStorage) = 0 Then _
            Return 0
    End If
    value.prelude = oldValue.prelude & storage & " = " & _
        valueForStorage & Chr(10)
    value.text = oldValue.text
    If isPostfix = 0 Then
        Dim result As String = NewSimpleTemporary(parser, value.typeName)
        If result = "" Then Return 0
        value.prelude &= result & " = " & valueAfterStorage & Chr(10)
        value.text = result
    End If
    value.isLValue = 0
    value.lValueText = ""
    value.isWholeCall = 0
    value.layoutType = value.typeName
    value.storageType = value.typeName
    value.bitWidth = -1
    value.bitOffset = 0
    value.bitStorageText = ""
    value.isDirectBitField = 0
    value.isPackedBitField = 0
    value.isUnsignedBitField = 0
    value.isSignedBitField = 0
    Return -1
End Function

/' end of c2fb_sequence.bi '/
