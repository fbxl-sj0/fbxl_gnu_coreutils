/'
    Project: C2FB generic header converter

    File: c2fb_generic_occurrences.bi

    Purpose:

        Apply occurrence-based removals to generic-header symbols.

    Responsibilities:

        - Merge declarations, inline function bodies, and macro definitions in input order.
        - Remove the first or repeated occurrences selected by caller patterns.
        - Track selected declarators, record aliases, and enum members separately.
        - Restore an earlier macro definition when only its first occurrence remains.

    This file intentionally does NOT contain:

        - C declaration parsing or macro expression lowering.
        - Removal of C record fields or C enum type bodies.
'/

Private Enum C2fbGenericHeaderOccurrenceKind
    C2FB_HEADER_OCCURRENCE_INVALID = 0
    C2FB_HEADER_OCCURRENCE_FUNCTION = 1
    C2FB_HEADER_OCCURRENCE_PLAIN_DECLARATOR = 2
    C2FB_HEADER_OCCURRENCE_RECORD = 3
    C2FB_HEADER_OCCURRENCE_ENUM_MEMBER = 4
    C2FB_HEADER_OCCURRENCE_MACRO = 5
End Enum

Private Type C2fbGenericHeaderOccurrenceEventModel
    sourceName As String
    inputOrder As LongInt
    declarationIndex As Long
    macroOccurrenceIndex As Long
    partIndex As Long
    kind As C2fbGenericHeaderOccurrenceKind
    isSuppressed As Long
    isInlineFunctionBody As Long
End Type

Private Function GenericHeaderOccurrenceEventPrecedes( _
    ByRef leftEvent As C2fbGenericHeaderOccurrenceEventModel, _
    ByRef rightEvent As C2fbGenericHeaderOccurrenceEventModel _
) As Long
    If leftEvent.sourceName < rightEvent.sourceName Then Return -1
    If leftEvent.sourceName > rightEvent.sourceName Then Return 0
    If leftEvent.inputOrder < rightEvent.inputOrder Then Return -1
    If leftEvent.inputOrder > rightEvent.inputOrder Then Return 0
    If leftEvent.partIndex < rightEvent.partIndex Then Return -1
    If leftEvent.partIndex > rightEvent.partIndex Then Return 0
    Return CInt(leftEvent.kind < rightEvent.kind)
End Function

Private Function AppendGenericHeaderOccurrenceEvent( _
    events() As C2fbGenericHeaderOccurrenceEventModel, _
    ByRef eventCount As Long, _
    ByRef occurrence As C2fbGenericHeaderOccurrenceEventModel _
) As Long
    If eventCount >= MAX_GENERIC_HEADER_OCCURRENCES Then Return 0
    If eventCount > UBound(events) Then _
        ReDim Preserve events(0 To UBound(events) * 2 + 1)
    events(eventCount) = occurrence
    eventCount += 1
    Return -1
End Function

Private Sub SortGenericHeaderOccurrenceEvents( _
    events() As C2fbGenericHeaderOccurrenceEventModel, _
    ByVal eventCount As Long _
)
    Dim gap As Long = eventCount \ 2
    While gap > 0
        For index As Long = gap To eventCount - 1
            Dim heldEvent As C2fbGenericHeaderOccurrenceEventModel = events(index)
            Dim destination As Long = index
            While destination >= gap AndAlso _
                  GenericHeaderOccurrenceEventPrecedes( _
                      heldEvent, events(destination - gap)) <> 0
                events(destination) = events(destination - gap)
                destination -= gap
            Wend
            events(destination) = heldEvent
        Next
        gap \= 2
    Wend
End Sub

Private Sub DisableGenericHeaderMacro( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
)
    Dim macroIndex As Long = GenericHeaderMacroIndexInContext( _
        translation, sourceName)
    If macroIndex >= 0 Then _
        translation.genericC.header.headerMacros(macroIndex).active = 0
End Sub

Private Function GenericHeaderFunctionOccurrenceRemoved( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByVal inputOrder As LongInt _
) As Long
    Dim key As String = sourceName & "#" & Trim(Str(inputOrder))
    Return CInt(C2fbStringIndexMapLookup( _
        translation.genericC.header.functionOccurrenceIndex, key) >= 0) * -1
End Function

Private Function GenericHeaderPlainDeclaratorRemoved( _
    ByRef sourceDeclaration As C2fbDeclarationModel, ByVal sourceName As String _
) As Long
    For nameIndex As Long = 0 To sourceDeclaration.removedDeclaratorCount - 1
        If sourceDeclaration.removedDeclarators(nameIndex) = sourceName Then Return -1
    Next
    Return 0
End Function

Private Function GenericHeaderEnumMemberRemoved( _
    ByRef sourceDeclaration As C2fbDeclarationModel, ByVal sourceName As String _
) As Long
    For nameIndex As Long = 0 To sourceDeclaration.removedEnumMemberCount - 1
        If sourceDeclaration.removedEnumMembers(nameIndex) = sourceName Then Return -1
    Next
    Return 0
End Function

Declare Sub AppendGenericHeaderInlineFunctionEvents( _
    ByRef translation As C2fbTranslationContext, _
    ByVal preprocessedPath As String, ByVal sourcePath As String, _
    events() As C2fbGenericHeaderOccurrenceEventModel, _
    ByRef eventCount As Long _
)

Private Sub RecordGenericHeaderRemovedName( _
    ByRef sourceDeclaration As C2fbDeclarationModel, _
    ByVal sourceName As String, ByVal isEnumMember As Long _
)
    If isEnumMember <> 0 Then
        For nameIndex As Long = 0 To sourceDeclaration.removedEnumMemberCount - 1
            If sourceDeclaration.removedEnumMembers(nameIndex) = sourceName Then Exit Sub
        Next
        If sourceDeclaration.removedEnumMemberCount >= MAX_FUNCTIONS Then _
            ReportError("too many removed generic-header enum members")
        If sourceDeclaration.removedEnumMemberCount = 0 Then
            ReDim sourceDeclaration.removedEnumMembers(0 To 7)
        ElseIf sourceDeclaration.removedEnumMemberCount > _
               UBound(sourceDeclaration.removedEnumMembers) Then
            ReDim Preserve sourceDeclaration.removedEnumMembers( _
                0 To UBound(sourceDeclaration.removedEnumMembers) * 2 + 1)
        End If
        sourceDeclaration.removedEnumMembers( _
            sourceDeclaration.removedEnumMemberCount) = sourceName
        sourceDeclaration.removedEnumMemberCount += 1
    Else
        For nameIndex As Long = 0 To sourceDeclaration.removedDeclaratorCount - 1
            If sourceDeclaration.removedDeclarators(nameIndex) = sourceName Then Exit Sub
        Next
        If sourceDeclaration.removedDeclaratorCount >= MAX_FUNCTIONS Then _
            ReportError("too many removed generic-header declarators")
        If sourceDeclaration.removedDeclaratorCount = 0 Then
            ReDim sourceDeclaration.removedDeclarators(0 To 7)
        ElseIf sourceDeclaration.removedDeclaratorCount > _
               UBound(sourceDeclaration.removedDeclarators) Then
            ReDim Preserve sourceDeclaration.removedDeclarators( _
                0 To UBound(sourceDeclaration.removedDeclarators) * 2 + 1)
        End If
        sourceDeclaration.removedDeclarators( _
            sourceDeclaration.removedDeclaratorCount) = sourceName
        sourceDeclaration.removedDeclaratorCount += 1
    End If
End Sub

Private Sub AppendGenericHeaderPlainDeclarationEvents( _
    ByRef translation As C2fbTranslationContext, ByVal declarationIndex As Long, _
    events() As C2fbGenericHeaderOccurrenceEventModel, _
    ByRef eventCount As Long _
)
    With translation.sourceUnit.declarations(declarationIndex)
        Dim parts() As String
        Dim partCount As Long
        If SplitSimpleCList(.text, parts(), partCount) = 0 OrElse partCount = 0 Then Exit Sub
        Dim commonType As String
        For partIndex As Long = 0 To partCount - 1
            Dim itemDeclaration As String = Trim(parts(partIndex))
            If partIndex > 0 Then itemDeclaration = commonType & " " & itemDeclaration
            Dim itemCommonType As String
            Dim sourceName As String
            Dim bindingOrder As String
            If ParseGenericHeaderDeclarator( _
                itemDeclaration, itemCommonType, sourceName, bindingOrder) = 0 Then _
                Continue For
            If partIndex = 0 Then commonType = itemCommonType
            Dim occurrence As C2fbGenericHeaderOccurrenceEventModel
            occurrence.sourceName = sourceName
            occurrence.inputOrder = .inputOrder
            occurrence.declarationIndex = declarationIndex
            occurrence.macroOccurrenceIndex = -1
            occurrence.partIndex = partIndex
            occurrence.kind = C2FB_HEADER_OCCURRENCE_PLAIN_DECLARATOR
            If AppendGenericHeaderOccurrenceEvent( _
                events(), eventCount, occurrence) = 0 Then _
                ReportError("generic-header symbol occurrences exceed the configured limit")
        Next
    End With
End Sub

Private Sub AppendGenericHeaderRecordEvents( _
    ByRef translation As C2fbTranslationContext, ByVal declarationIndex As Long, _
    events() As C2fbGenericHeaderOccurrenceEventModel, _
    ByRef eventCount As Long _
)
    With translation.sourceUnit.declarations(declarationIndex)
        Dim typedefParts() As String
        Dim typedefAliasNames() As String
        Dim typedefBindingOrders() As String
        Dim typedefPartCount As Long
        Dim hasRecordTypedefTail As Long = 0
        If .isTypedef <> 0 AndAlso .recordTail <> "" Then
            hasRecordTypedefTail = ParseGenericRecordTypedefTail( _
                .recordTail, typedefParts(), typedefAliasNames(), _
                typedefBindingOrders(), typedefPartCount)
        End If

        If hasRecordTypedefTail <> 0 Then
            If .recordTag <> "" Then
                Dim tagOccurrence As C2fbGenericHeaderOccurrenceEventModel
                tagOccurrence.sourceName = .recordTag
                tagOccurrence.inputOrder = .inputOrder
                tagOccurrence.declarationIndex = declarationIndex
                tagOccurrence.macroOccurrenceIndex = -1
                tagOccurrence.partIndex = -1
                tagOccurrence.kind = C2FB_HEADER_OCCURRENCE_RECORD
                If AppendGenericHeaderOccurrenceEvent( _
                    events(), eventCount, tagOccurrence) = 0 Then _
                    ReportError("generic-header symbol occurrences exceed the configured limit")
            ElseIf typedefPartCount = 1 Then
                ' Keep single-name anonymous records as one record occurrence.
                ' Removing that name should remove the layout that owns it.
                Dim recordOccurrence As C2fbGenericHeaderOccurrenceEventModel
                recordOccurrence.sourceName = typedefAliasNames(0)
                recordOccurrence.inputOrder = .inputOrder
                recordOccurrence.declarationIndex = declarationIndex
                recordOccurrence.macroOccurrenceIndex = -1
                recordOccurrence.partIndex = -1
                recordOccurrence.kind = C2FB_HEADER_OCCURRENCE_RECORD
                If AppendGenericHeaderOccurrenceEvent( _
                    events(), eventCount, recordOccurrence) = 0 Then _
                    ReportError("generic-header symbol occurrences exceed the configured limit")
            End If

            For aliasIndex As Long = 0 To typedefPartCount - 1
                If .recordTag <> "" AndAlso _
                   typedefAliasNames(aliasIndex) = .recordTag Then Continue For
                If .recordTag = "" AndAlso typedefPartCount = 1 Then Continue For
                Dim aliasOccurrence As C2fbGenericHeaderOccurrenceEventModel
                aliasOccurrence.sourceName = typedefAliasNames(aliasIndex)
                aliasOccurrence.inputOrder = .inputOrder
                aliasOccurrence.declarationIndex = declarationIndex
                aliasOccurrence.macroOccurrenceIndex = -1
                aliasOccurrence.partIndex = aliasIndex
                aliasOccurrence.kind = C2FB_HEADER_OCCURRENCE_PLAIN_DECLARATOR
                If AppendGenericHeaderOccurrenceEvent( _
                    events(), eventCount, aliasOccurrence) = 0 Then _
                    ReportError("generic-header symbol occurrences exceed the configured limit")
            Next
        Else
            Dim typeName As String = IIf(.recordAlias <> "", .recordAlias, .recordTag)
            If typeName <> "" Then
                Dim occurrence As C2fbGenericHeaderOccurrenceEventModel
                occurrence.sourceName = typeName
                occurrence.inputOrder = .inputOrder
                occurrence.declarationIndex = declarationIndex
                occurrence.macroOccurrenceIndex = -1
                occurrence.partIndex = -1
                occurrence.kind = C2FB_HEADER_OCCURRENCE_RECORD
                If AppendGenericHeaderOccurrenceEvent( _
                    events(), eventCount, occurrence) = 0 Then _
                    ReportError("generic-header symbol occurrences exceed the configured limit")
            End If
            If .recordTag <> "" AndAlso .recordAlias <> "" AndAlso _
               .recordAlias <> .recordTag Then
                Dim tagOccurrence As C2fbGenericHeaderOccurrenceEventModel
                tagOccurrence.sourceName = .recordTag
                tagOccurrence.inputOrder = .inputOrder
                tagOccurrence.declarationIndex = declarationIndex
                tagOccurrence.macroOccurrenceIndex = -1
                tagOccurrence.partIndex = -1
                tagOccurrence.kind = C2FB_HEADER_OCCURRENCE_RECORD
                If AppendGenericHeaderOccurrenceEvent( _
                    events(), eventCount, tagOccurrence) = 0 Then _
                    ReportError("generic-header symbol occurrences exceed the configured limit")
            End If
        End If
        If .isTypedef = 0 AndAlso _
           (.recordTag <> "" OrElse .recordAlias <> "") AndAlso _
           .recordTail <> "" Then
            Dim trailingParts() As String
            Dim trailingNames() As String
            Dim trailingBindingOrders() As String
            Dim trailingPartCount As Long
            If ParseGenericRecordTypedefTail( _
                .recordTail, trailingParts(), trailingNames(), _
                trailingBindingOrders(), trailingPartCount) <> 0 Then
                For partIndex As Long = 0 To trailingPartCount - 1
                    Dim objectOccurrence As C2fbGenericHeaderOccurrenceEventModel
                    objectOccurrence.sourceName = trailingNames(partIndex)
                    objectOccurrence.inputOrder = .inputOrder
                    objectOccurrence.declarationIndex = declarationIndex
                    objectOccurrence.macroOccurrenceIndex = -1
                    objectOccurrence.partIndex = partIndex
                    objectOccurrence.kind = C2FB_HEADER_OCCURRENCE_PLAIN_DECLARATOR
                    If AppendGenericHeaderOccurrenceEvent( _
                        events(), eventCount, objectOccurrence) = 0 Then _
                        ReportError("generic-header symbol occurrences exceed the configured limit")
                Next
            End If
        End If
        If .recordKind <> C2FB_RECORD_ENUM OrElse Trim(.recordBody) = "" Then Exit Sub
        Dim enumParts() As String
        Dim enumPartCount As Long
        If SplitSimpleCList( _
            .recordBody, enumParts(), enumPartCount, -1) = 0 Then Exit Sub
        For enumPartIndex As Long = 0 To enumPartCount - 1
            Dim enumTokens() As String
            Dim enumTokenCount As Long
            TokenizeCDeclaration(Trim(enumParts(enumPartIndex)), enumTokens(), enumTokenCount)
            If enumTokenCount = 0 OrElse IsIdentifierToken(enumTokens(0)) = 0 Then Continue For
            Dim enumOccurrence As C2fbGenericHeaderOccurrenceEventModel
            enumOccurrence.sourceName = enumTokens(0)
            enumOccurrence.inputOrder = .inputOrder
            enumOccurrence.declarationIndex = declarationIndex
            enumOccurrence.macroOccurrenceIndex = -1
            enumOccurrence.partIndex = enumPartIndex
            enumOccurrence.kind = C2FB_HEADER_OCCURRENCE_ENUM_MEMBER
            If AppendGenericHeaderOccurrenceEvent( _
                events(), eventCount, enumOccurrence) = 0 Then _
                ReportError("generic-header symbol occurrences exceed the configured limit")
        Next
    End With
End Sub

Private Sub RestoreGenericHeaderMacroOccurrence( _
    ByRef translation As C2fbTranslationContext, ByVal occurrenceIndex As Long _
)
    If occurrenceIndex < 0 OrElse _
       occurrenceIndex >= translation.genericC.header.macroOccurrenceCount Then Exit Sub
    Dim macroDefinition As C2fbMacroDefinitionModel = _
        translation.genericC.header.macroOccurrences(occurrenceIndex)
    If macroDefinition.functionLike <> 0 Then _
        TokenizeCDeclaration( _
            macroDefinition.rawValue, macroDefinition.tokens(), _
            macroDefinition.tokenCount)
    SetGenericHeaderMacroInContext(translation, macroDefinition)
End Sub

Private Sub ApplyGenericHeaderOccurrenceRemovals( _
    ByRef translation As C2fbTranslationContext, _
    ByVal preprocessedPath As String, ByVal sourcePath As String _
)
    ResetC2fbStringIndexMap( _
        translation.genericC.header.functionOccurrenceIndex)
    If translation.genericC.policy.removeFirstPatternCount = 0 AndAlso _
       translation.genericC.policy.removeRepeatedPatternCount = 0 Then Exit Sub

    Dim events() As C2fbGenericHeaderOccurrenceEventModel
    ReDim events(0 To 255)
    Dim eventCount As Long = 0

    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If GenericSourceIncludedInPolicy( _
                translation.genericC.policy, .sourceSpan.startLocation.path) = 0 Then _
                Continue For
            If .entryKind = C2FB_DECLARATION_FUNCTION Then
                If .sourceName = "" Then Continue For
                Dim occurrence As C2fbGenericHeaderOccurrenceEventModel
                occurrence.sourceName = .sourceName
                occurrence.inputOrder = .inputOrder
                occurrence.declarationIndex = declarationIndex
                occurrence.macroOccurrenceIndex = -1
                occurrence.partIndex = -1
                occurrence.kind = C2FB_HEADER_OCCURRENCE_FUNCTION
                If AppendGenericHeaderOccurrenceEvent( _
                    events(), eventCount, occurrence) = 0 Then _
                    ReportError("generic-header symbol occurrences exceed the configured limit")
            ElseIf .entryKind = C2FB_DECLARATION_PLAIN Then
                AppendGenericHeaderPlainDeclarationEvents( _
                    translation, declarationIndex, events(), eventCount)
            ElseIf .entryKind = C2FB_DECLARATION_RECORD Then
                AppendGenericHeaderRecordEvents( _
                    translation, declarationIndex, events(), eventCount)
            End If
        End With
    Next

    AppendGenericHeaderInlineFunctionEvents( _
        translation, preprocessedPath, sourcePath, events(), eventCount)

    For macroIndex As Long = 0 To _
        translation.genericC.header.macroOccurrenceCount - 1
        With translation.genericC.header.macroOccurrences(macroIndex)
            If .sourceName = "" OrElse GenericSourceIncludedInPolicy( _
                translation.genericC.policy, .sourceLocation.path) = 0 Then Continue For
            Dim occurrence As C2fbGenericHeaderOccurrenceEventModel
            occurrence.sourceName = .sourceName
            occurrence.inputOrder = .inputOrder
            occurrence.declarationIndex = -1
            occurrence.macroOccurrenceIndex = macroIndex
            occurrence.partIndex = -1
            occurrence.kind = C2FB_HEADER_OCCURRENCE_MACRO
            If AppendGenericHeaderOccurrenceEvent( _
                events(), eventCount, occurrence) = 0 Then _
                ReportError("generic-header symbol occurrences exceed the configured limit")
        End With
    Next

    SortGenericHeaderOccurrenceEvents(events(), eventCount)

    Dim groupStart As Long = 0
    While groupStart < eventCount
        Dim groupEnd As Long = groupStart + 1
        While groupEnd < eventCount AndAlso _
              events(groupEnd).sourceName = events(groupStart).sourceName
            groupEnd += 1
        Wend
        Dim sourceName As String = events(groupStart).sourceName
        Dim removeFirst As Long = _
            GenericSymbolRemoveFirstInPolicy(translation.genericC.policy, sourceName)
        Dim removeRepeated As Long = _
            GenericSymbolRemoveRepeatedInPolicy(translation.genericC.policy, sourceName)
        If removeFirst <> 0 OrElse removeRepeated <> 0 Then
            Dim firstRetainedIndex As Long = -1
            For eventIndex As Long = groupStart To groupEnd - 1
                If eventIndex = groupStart AndAlso removeFirst <> 0 Then
                    events(eventIndex).isSuppressed = -1
                ElseIf removeRepeated <> 0 Then
                    If firstRetainedIndex < 0 Then
                        firstRetainedIndex = eventIndex
                    Else
                        events(eventIndex).isSuppressed = -1
                    End If
                End If
                If events(eventIndex).isSuppressed <> 0 AndAlso _
                   events(eventIndex).declarationIndex >= 0 Then
                    Select Case events(eventIndex).kind
                    Case C2FB_HEADER_OCCURRENCE_FUNCTION, _
                         C2FB_HEADER_OCCURRENCE_RECORD
                        translation.sourceUnit.declarations( _
                            events(eventIndex).declarationIndex).removeFromGenericHeader = -1
                    Case C2FB_HEADER_OCCURRENCE_PLAIN_DECLARATOR
                        RecordGenericHeaderRemovedName( _
                            translation.sourceUnit.declarations( _
                                events(eventIndex).declarationIndex), _
                            events(eventIndex).sourceName, 0)
                    Case C2FB_HEADER_OCCURRENCE_ENUM_MEMBER
                        RecordGenericHeaderRemovedName( _
                            translation.sourceUnit.declarations( _
                                events(eventIndex).declarationIndex), _
                            events(eventIndex).sourceName, -1)
                    End Select
                ElseIf events(eventIndex).isSuppressed <> 0 AndAlso _
                       events(eventIndex).isInlineFunctionBody <> 0 Then
                    Dim functionKey As String = _
                        events(eventIndex).sourceName & "#" & _
                        Trim(Str(events(eventIndex).inputOrder))
                    If AddC2fbStringIndexMapEntry( _
                        translation.genericC.header.functionOccurrenceIndex, _
                        functionKey, eventIndex) = 0 Then _
                        ReportError("generic header function-occurrence index exceeds its configured limit")
                End If
            Next

            If removeRepeated <> 0 Then
                If firstRetainedIndex >= 0 AndAlso _
                   events(firstRetainedIndex).kind = _
                       C2FB_HEADER_OCCURRENCE_MACRO Then
                    RestoreGenericHeaderMacroOccurrence( _
                        translation, events(firstRetainedIndex).macroOccurrenceIndex)
                Else
                    DisableGenericHeaderMacro(translation, sourceName)
                End If
            ElseIf removeFirst <> 0 Then
                Dim lastMacroEvent As Long = -1
                For eventIndex As Long = groupStart To groupEnd - 1
                    If events(eventIndex).kind = _
                       C2FB_HEADER_OCCURRENCE_MACRO Then lastMacroEvent = eventIndex
                Next
                If lastMacroEvent >= 0 AndAlso _
                   events(lastMacroEvent).isSuppressed <> 0 Then _
                    DisableGenericHeaderMacro(translation, sourceName)
            End If
        End If
        groupStart = groupEnd
    Wend
End Sub

Private Sub PrepareGenericHeaderFunctionPrototypeIndex( _
    ByRef translation As C2fbTranslationContext _
)
    ResetC2fbStringIndexMap(translation.genericC.header.functionPrototypeIndex)
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_FUNCTION OrElse _
               .isFunctionDefinition <> 0 OrElse _
               .removeFromGenericHeader <> 0 OrElse _
               .sourceName = "" OrElse _
               GenericSourceIncludedInPolicy( _
                   translation.genericC.policy, _
                   .sourceSpan.startLocation.path) = 0 Then Continue For
            If C2fbStringIndexMapLookup( _
                translation.genericC.header.functionPrototypeIndex, _
                .sourceName) < 0 AndAlso _
               AddC2fbStringIndexMapEntry( _
                translation.genericC.header.functionPrototypeIndex, _
                .sourceName, declarationIndex) = 0 Then _
                ReportError("generic header function-prototype index exceeds its configured limit")
        End With
    Next
End Sub

/' end of c2fb_generic_occurrences.bi '/
