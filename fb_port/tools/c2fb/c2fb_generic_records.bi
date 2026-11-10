/'
    Project: C2FB generic header converter

    File: c2fb_generic_records.bi

    Purpose:

        Prepare, validate, and emit generic C record layouts.

    Responsibilities:

        - Prepare record aliases and layouts from shared declaration models.
        - Keep target names and support decisions in generic record plans.
        - Preserve record bodies until typedef and tag names are known.
        - Add FreeBASIC forward aliases before emitting dependent records.
        - Emit ABI layouts for ordinary structs and unions with supported fields.
        - Emit scalar bitfields only when C and FreeBASIC storage extents match.
        - Preserve explicit packing directives in emitted record layouts.
        - Parse record fields into shared field-binding models.
        - Ignore non-layout string-array attributes while rejecting attributes
          that can change field layout.
        - Map supported anonymous enum members to the target C int field layout.
        - Preserve anonymous and named inline struct/union members in record output.
        - Replace trailing byte-tail arrays with pointer accessor macros.

    This file intentionally does NOT contain:

        - C preprocessing, C function-body conversion, or SQLite port mappings.
        - Generic-header pass orchestration, external declarations, or macros.
        - Scanner-level extraction of tagged nested records.
        - Zero-width bitfields or non-byte flexible arrays.
'/

' FreeBASIC anonymous Type/Union blocks alternate; bound both source and emitted depth.
Private Const MAX_GENERIC_RECORD_NESTING As Long = 16
Private Const MAX_GENERIC_RECORD_OUTPUT_NESTING As Long = _
    MAX_GENERIC_RECORD_NESTING * 2

Declare Sub AppendC2fbDeclarationInSourceUnit( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByRef declaration As C2fbDeclarationModel _
)

Declare Function GenericRecordOnlyPackedTopLevelAggregate( _
    fields() As GenericRecordField, ByVal fieldCount As Long _
) As Long

Declare Function GenericRecordBindingNaturalAlignmentBytes( _
    ByRef translation As C2fbTranslationContext, _
    ByRef recordBinding As C2fbRecordBindingModel _
) As Long

Declare Function GenericRecordBindingHasNestedAggregate( _
    ByRef translation As C2fbTranslationContext, _
    ByRef recordBinding As C2fbRecordBindingModel _
) As Long

Declare Function GenericPreprocessorTypeWidthInBits( _
    ByRef translation As C2fbTranslationContext, ByVal macroName As String, _
    ByVal fallbackBytes As Long _
) As Long

Private Function ParseGenericRecordTypedefTail( _
    ByVal recordTail As String, parts() As String, aliasNames() As String, _
    bindingOrders() As String, ByRef partCount As Long _
) As Long
    partCount = 0
    Dim normalizedTail As String = Trim(recordTail)
    If Right(normalizedTail, 1) = ";" Then _
        normalizedTail = Trim(Left(normalizedTail, Len(normalizedTail) - 1))
    If normalizedTail = "" OrElse _
       SplitSimpleCList(normalizedTail, parts(), partCount) = 0 OrElse _
       partCount = 0 Then Return 0

    ReDim aliasNames(0 To partCount - 1)
    ReDim bindingOrders(0 To partCount - 1)
    For partIndex As Long = 0 To partCount - 1
        Dim normalizedPart As String = StripCFunctionAttributes(parts(partIndex))
        Dim tokens() As String
        Dim tokenCount As Long
        TokenizeCDeclaration(normalizedPart, tokens(), tokenCount)
        If tokenCount <= 0 OrElse tokenCount >= MAX_TYPE_WORDS Then Return 0

        Dim position As Long = 0
        Dim declarator As C2fbDeclaratorModel
        If ParseCDeclaratorModel( _
            tokens(), position, tokenCount - 1, declarator) = 0 OrElse _
           position <> tokenCount OrElse _
           IsIdentifierToken(declarator.name) = 0 Then Return 0
        aliasNames(partIndex) = declarator.name
        bindingOrders(partIndex) = declarator.bindingOrder
    Next
    Return -1
End Function

Private Function GenericRecordTypedefDeclaratorRemoved( _
    ByRef declaration As C2fbDeclarationModel, ByVal sourceName As String _
) As Long
    For nameIndex As Long = 0 To declaration.removedDeclaratorCount - 1
        If declaration.removedDeclarators(nameIndex) = sourceName Then Return -1
    Next
    Return 0
End Function

Private Function ExpandGenericHeaderRecordTypedefAliases( _
    ByRef translation As C2fbTranslationContext _
) As Long
    Dim originalDeclarationCount As Long = _
        translation.sourceUnit.declarationCount
    For declarationIndex As Long = 0 To originalDeclarationCount - 1
        Dim declaration As C2fbDeclarationModel = _
            translation.sourceUnit.declarations(declarationIndex)
        If declaration.entryKind <> C2FB_DECLARATION_RECORD OrElse _
           declaration.isTypedef = 0 OrElse declaration.recordTail = "" OrElse _
           declaration.removeFromGenericHeader <> 0 OrElse _
           declaration.unsupported <> 0 Then Continue For

        Dim parts() As String
        Dim aliasNames() As String
        Dim bindingOrders() As String
        Dim partCount As Long
        If ParseGenericRecordTypedefTail( _
            declaration.recordTail, parts(), aliasNames(), bindingOrders(), _
            partCount) = 0 Then
            declaration.unsupported = -1
            translation.sourceUnit.declarations(declarationIndex) = declaration
            Continue For
        End If

        Dim canonicalAlias As String
        For partIndex As Long = 0 To partCount - 1
            If bindingOrders(partIndex) <> "" OrElse _
               GenericRecordTypedefDeclaratorRemoved( _
                   declaration, aliasNames(partIndex)) <> 0 Then Continue For
            canonicalAlias = aliasNames(partIndex)
            Exit For
        Next

        Dim recordTypeName As String
        If declaration.recordTag <> "" Then
            Select Case declaration.recordKind
            Case C2FB_RECORD_STRUCT: recordTypeName = "struct " & declaration.recordTag
            Case C2FB_RECORD_UNION: recordTypeName = "union " & declaration.recordTag
            Case C2FB_RECORD_ENUM: recordTypeName = "enum " & declaration.recordTag
            End Select
        ElseIf canonicalAlias <> "" Then
            recordTypeName = canonicalAlias
        ElseIf declaration.recordAlias <> "" Then
            ' Pointer-only anonymous groups use a synthetic tag as their base
            ' type, then lower each C typedef alias against it.
            canonicalAlias = declaration.recordAlias
            recordTypeName = canonicalAlias
        Else
            declaration.unsupported = -1
            declaration.recordAlias = ""
            translation.sourceUnit.declarations(declarationIndex) = declaration
            Continue For
        End If

        declaration.recordAlias = canonicalAlias
        translation.sourceUnit.declarations(declarationIndex) = declaration
        For partIndex As Long = 0 To partCount - 1
            If GenericRecordTypedefDeclaratorRemoved( _
                declaration, aliasNames(partIndex)) <> 0 Then Continue For
            If aliasNames(partIndex) = canonicalAlias AndAlso _
               bindingOrders(partIndex) = "" Then Continue For

            Dim aliasDeclaration As C2fbDeclarationModel
            aliasDeclaration.entryKind = C2FB_DECLARATION_PLAIN
            aliasDeclaration.text = "typedef " & recordTypeName & " " & _
                Trim(parts(partIndex))
            aliasDeclaration.sourceSpan = declaration.sourceSpan
            aliasDeclaration.inputOrder = declaration.inputOrder
            AppendC2fbDeclarationInSourceUnit( _
                translation.sourceUnit, aliasDeclaration)
        Next
    Next
    Return -1
End Function

Private Function ExpandGenericHeaderRecordTrailingDeclarators( _
    ByRef translation As C2fbTranslationContext _
) As Long
    Dim originalDeclarationCount As Long = _
        translation.sourceUnit.declarationCount
    For declarationIndex As Long = 0 To originalDeclarationCount - 1
        Dim declaration As C2fbDeclarationModel = _
            translation.sourceUnit.declarations(declarationIndex)
        If declaration.entryKind <> C2FB_DECLARATION_RECORD OrElse _
           declaration.isTypedef <> 0 OrElse _
           (declaration.recordTag = "" AndAlso declaration.recordAlias = "") OrElse _
           declaration.recordTail = "" OrElse declaration.removeFromGenericHeader <> 0 OrElse _
           declaration.unsupported <> 0 OrElse _
           (declaration.recordKind <> C2FB_RECORD_STRUCT AndAlso _
            declaration.recordKind <> C2FB_RECORD_UNION AndAlso _
            declaration.recordKind <> C2FB_RECORD_ENUM) OrElse _
           GenericSourceIncludedInPolicy( _
                translation.genericC.policy, _
                declaration.sourceSpan.startLocation.path) = 0 Then Continue For
        If declarationIndex > UBound(translation.genericC.header.recordPlans) Then Continue For

        Dim plan As C2fbGenericRecordPlanModel = _
            translation.genericC.header.recordPlans(declarationIndex)
        If plan.isSupported = 0 OrElse plan.isExcluded <> 0 Then Continue For
        If declaration.recordKind <> C2FB_RECORD_ENUM AndAlso _
           plan.bindingReady = 0 Then Continue For

        Dim parts() As String
        Dim declaratorNames() As String
        Dim bindingOrders() As String
        Dim partCount As Long
        If ParseGenericRecordTypedefTail( _
            declaration.recordTail, parts(), declaratorNames(), _
            bindingOrders(), partCount) = 0 Then Continue For

        Dim recordTypePrefix As String
        If declaration.recordTag <> "" Then
            recordTypePrefix = Trim(StripCFunctionAttributes(declaration.recordPrefix))
        Else
            Dim prefixTokens() As String
            Dim prefixTokenCount As Long
            TokenizeCDeclaration( _
                StripCFunctionAttributes(declaration.recordPrefix), _
                prefixTokens(), prefixTokenCount)
            For tokenIndex As Long = 0 To prefixTokenCount - 1
                Select Case prefixTokens(tokenIndex)
                Case "struct", "union", "enum"
                    Exit For
                Case "static", "extern", "register", "const", "volatile", _
                     "__thread", "_Thread_local"
                    If recordTypePrefix <> "" Then recordTypePrefix &= " "
                    recordTypePrefix &= prefixTokens(tokenIndex)
                End Select
            Next
            If recordTypePrefix <> "" Then recordTypePrefix &= " "
            recordTypePrefix &= declaration.recordAlias
        End If
        For partIndex As Long = 0 To partCount - 1
            If GenericRecordTypedefDeclaratorRemoved( _
                declaration, declaratorNames(partIndex)) <> 0 Then Continue For
            Dim trailingDeclaration As C2fbDeclarationModel
            trailingDeclaration.entryKind = C2FB_DECLARATION_PLAIN
            trailingDeclaration.text = recordTypePrefix & " " & _
                Trim(parts(partIndex))
            trailingDeclaration.sourceSpan = declaration.sourceSpan
            trailingDeclaration.inputOrder = declaration.inputOrder
            AppendC2fbDeclarationInSourceUnit( _
                translation.sourceUnit, trailingDeclaration)
        Next
    Next
    Return -1
End Function


Private Function PrepareGenericHeaderRecords( _
    ByRef translation As C2fbTranslationContext, _
    typeNames() As String, ByRef typeNameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long _
) As Long
    Dim planCapacity As Long = translation.sourceUnit.declarationCount
    If planCapacity <= 0 Then planCapacity = 1
    ReDim translation.genericC.header.recordPlans(0 To planCapacity - 1)
    translation.genericC.header.recordPlanCount = planCapacity

    ' Reserve all tag and typedef names before fields or procedures are emitted.
    ' This mirrors C's separate tag namespace and allows recursive pointer fields.
    For entryIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        If translation.sourceUnit.declarations(entryIndex).entryKind <> _
           C2FB_DECLARATION_RECORD Then Continue For
        Dim plan As C2fbGenericRecordPlanModel
        plan.sourceDeclarationIndex = entryIndex
        plan.isPrepared = -1
        With translation.sourceUnit.declarations(entryIndex)
            If .removeFromGenericHeader <> 0 Then
                plan.isExcluded = -1
                translation.genericC.header.recordPlans(entryIndex) = plan
                Continue For
            End If
            If (.recordTag <> "" AndAlso _
                GenericTypeExcludedInPolicy(translation.genericC.policy, .recordTag) <> 0) OrElse _
               (.recordAlias <> "" AndAlso _
                GenericTypeExcludedInPolicy(translation.genericC.policy, .recordAlias) <> 0) Then
                plan.isExcluded = -1
                translation.genericC.header.recordPlans(entryIndex) = plan
                Continue For
            End If
            If .unsupported <> 0 Then
                translation.genericC.header.recordPlans(entryIndex) = plan
                Continue For
            End If
            plan.isSupported = -1
            Dim recordStorageType As String = "Record"
            If .recordKind = C2FB_RECORD_ENUM Then recordStorageType = "Long"
            If .recordKind <> C2FB_RECORD_ENUM AndAlso _
               Trim(.recordBody) = "" Then
                Dim emptyRecordName As String = .recordTag
                If emptyRecordName = "" Then emptyRecordName = .recordAlias
                recordStorageType = GenericTypeOverrideInPolicy( _
                    translation.genericC.policy, emptyRecordName)
                If recordStorageType = "" Then recordStorageType = "Any"
                plan.isOpaqueEmpty = -1
            End If
            If .recordTag <> "" Then
                Dim tagIndex As Long = _
                    GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, .recordTag, -1)
                If tagIndex >= 0 Then
                    plan.freeBasicName = translation.genericC.header.headerTypeAliases(tagIndex).freeBasicName
                Else
                    plan.freeBasicName = GenericFreeBasicTypeNameInPolicy( _
                        translation, .recordTag, typeNames(), typeNameCount, _
                        outputNames(), outputNameCount, C2FB_SYMBOL_RENAME_TAG)
                    If typeNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                        ReportError("generic header exceeds the configured typedef limit")
                    If typeNameCount > UBound(typeNames) Then _
                        ReDim Preserve typeNames(0 To UBound(typeNames) * 2 + 1)
                    typeNames(typeNameCount) = plan.freeBasicName
                    typeNameCount += 1
                    If outputNameCount > UBound(outputNames) Then _
                        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                    outputNames(outputNameCount) = plan.freeBasicName
                    outputNameCount += 1
                    RecordGenericHeaderTypeAliasInHeader( _
                        translation.genericC.header, .recordTag, plan.freeBasicName, recordStorageType, 0, -1)
                End If
            ElseIf .recordAlias <> "" Then
                Dim aliasIndex As Long = _
                    GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, .recordAlias, 0)
                If aliasIndex >= 0 Then
                    plan.freeBasicName = translation.genericC.header.headerTypeAliases(aliasIndex).freeBasicName
                Else
                    plan.freeBasicName = GenericFreeBasicTypeNameInPolicy( _
                        translation, .recordAlias, typeNames(), typeNameCount, _
                        outputNames(), outputNameCount)
                    If typeNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                        ReportError("generic header exceeds the configured typedef limit")
                    If typeNameCount > UBound(typeNames) Then _
                        ReDim Preserve typeNames(0 To UBound(typeNames) * 2 + 1)
                    typeNames(typeNameCount) = plan.freeBasicName
                    typeNameCount += 1
                    If outputNameCount > UBound(outputNames) Then _
                        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                    outputNames(outputNameCount) = plan.freeBasicName
                    outputNameCount += 1
                    RecordGenericHeaderTypeAliasInHeader( _
                        translation.genericC.header, .recordAlias, plan.freeBasicName, recordStorageType)
                End If
            Else
                translation.genericC.header.recordPlans(entryIndex) = plan
                Continue For
            End If

            If .recordTag <> "" AndAlso .recordAlias <> "" Then
                Dim ordinaryIndex As Long = _
                    GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, .recordAlias, 0)
                If GenericTypedefExpansionRequestedInPolicy( _
                    translation.genericC.policy, .recordAlias) <> 0 Then
                    If ordinaryIndex < 0 Then
                        RecordGenericHeaderTypeAliasInHeader( _
                            translation.genericC.header, .recordAlias, _
                            plan.freeBasicName, recordStorageType, -1)
                    Else
                        translation.genericC.header.headerTypeAliases(ordinaryIndex).freeBasicName = _
                            plan.freeBasicName
                        translation.genericC.header.headerTypeAliases(ordinaryIndex).baseType = _
                            recordStorageType
                        translation.genericC.header.headerTypeAliases(ordinaryIndex).emitted = -1
                    End If
                    MarkGenericTypedefExpansionMatchedInPolicy( _
                        translation.genericC.policy, .recordAlias)
                ElseIf ordinaryIndex < 0 Then
                    Dim translatedAliasName As String = _
                        GenericFreeBasicTypeNameInPolicy( _
                            translation, .recordAlias, _
                            typeNames(), typeNameCount, outputNames(), _
                            outputNameCount, C2FB_SYMBOL_RENAME_TYPEDEF, _
                            plan.freeBasicName)
                    If translatedAliasName = plan.freeBasicName Then
                        RecordGenericHeaderTypeAliasInHeader( _
                            translation.genericC.header, .recordAlias, plan.freeBasicName, recordStorageType)
                    Else
                        plan.aliasFreeBasicName = translatedAliasName
                        If typeNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                            ReportError("generic header exceeds the configured typedef limit")
                        If typeNameCount > UBound(typeNames) Then _
                            ReDim Preserve typeNames(0 To UBound(typeNames) * 2 + 1)
                        typeNames(typeNameCount) = plan.aliasFreeBasicName
                        typeNameCount += 1
                        If outputNameCount > UBound(outputNames) Then _
                            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                        outputNames(outputNameCount) = plan.aliasFreeBasicName
                        outputNameCount += 1
                        RecordGenericHeaderTypeAliasInHeader( _
                            translation.genericC.header, .recordAlias, _
                            plan.aliasFreeBasicName, _
                            recordStorageType)
                    End If
                ElseIf ordinaryIndex >= 0 Then
                    plan.aliasFreeBasicName = translation.genericC.header.headerTypeAliases( _
                        ordinaryIndex).freeBasicName
                    If plan.aliasFreeBasicName = plan.freeBasicName Then
                        plan.aliasFreeBasicName = ""
                        If .recordAlias = .recordTag Then
                            Dim separateAliasName As String = _
                                GenericFreeBasicTypeNameInPolicy( _
                                    translation, .recordAlias, _
                                    typeNames(), typeNameCount, _
                                    outputNames(), outputNameCount, _
                                    C2FB_SYMBOL_RENAME_TYPEDEF)
                            If separateAliasName = plan.freeBasicName Then _
                                separateAliasName &= "_"
                            Do
                                Dim aliasNameConflict As Long = 0
                                Dim existingTypeAliasIndex As Long = _
                                    GenericHeaderTypeAliasIndexByFreeBasicNameInHeader( _
                                        translation.genericC.header, separateAliasName)
                                If existingTypeAliasIndex >= 0 AndAlso _
                                   translation.genericC.header.headerTypeAliases( _
                                       existingTypeAliasIndex).sourceName <> .recordAlias Then
                                    aliasNameConflict = -1
                                End If
                                If C2fbNameListContains( _
                                    outputNames(), outputNameCount, separateAliasName) <> 0 AndAlso _
                                   C2fbNameListContains( _
                                    typeNames(), typeNameCount, separateAliasName) = 0 Then
                                    aliasNameConflict = -1
                                End If
                                If aliasNameConflict = 0 Then Exit Do
                                separateAliasName &= "_"
                            Loop
                            If typeNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES OrElse _
                               outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                                ReportError("generic header exceeds the configured typedef limit")
                            If typeNameCount > UBound(typeNames) Then _
                                ReDim Preserve typeNames(0 To UBound(typeNames) * 2 + 1)
                            typeNames(typeNameCount) = separateAliasName
                            typeNameCount += 1
                            If outputNameCount > UBound(outputNames) Then _
                                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                            outputNames(outputNameCount) = separateAliasName
                            outputNameCount += 1
                            plan.aliasFreeBasicName = separateAliasName
                            With translation.genericC.header.headerTypeAliases(ordinaryIndex)
                                .freeBasicName = separateAliasName
                                .baseType = plan.freeBasicName
                                .emitted = 0
                                .isForward = 0
                            End With
                        End If
                    End If
                End If
            End If
            ' Stable, prefixed backing names keep unrelated generated headers
            ' from reusing an index-based implementation type name.
            If plan.isOpaqueEmpty <> 0 Then
                plan.implementationName = recordStorageType
            Else
                plan.implementationName = _
                    "_" & translation.genericC.policy.generatedNamePrefix & "record_" & plan.freeBasicName
            End If
            Dim recordSourceName As String = .recordTag
            If recordSourceName = "" Then recordSourceName = .recordAlias
            plan.ifndefGuardName = GenericDeclarationIfndefGuardNameInPolicy( _
                translation.genericC.policy, recordSourceName, plan.freeBasicName)
            plan.undefBeforeName = GenericDeclarationUndefBeforeNameInPolicy( _
                translation.genericC.policy, recordSourceName, plan.freeBasicName)
            If .recordAlias <> "" AndAlso .recordAlias <> recordSourceName Then
                Dim aliasIfndefGuardName As String = _
                    GenericDeclarationIfndefGuardNameInPolicy( _
                        translation.genericC.policy, .recordAlias, plan.aliasFreeBasicName)
                Dim aliasUndefBeforeName As String = _
                    GenericDeclarationUndefBeforeNameInPolicy( _
                        translation.genericC.policy, .recordAlias, plan.aliasFreeBasicName)
                If plan.ifndefGuardName = "" Then _
                    plan.ifndefGuardName = aliasIfndefGuardName
                If plan.undefBeforeName = "" Then _
                    plan.undefBeforeName = aliasUndefBeforeName
            End If
            If .recordAlias <> "" AndAlso .typedefAlignment > 0 Then
                Dim typedefAliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
                    translation.genericC.header, .recordAlias, 0)
                If typedefAliasIndex >= 0 Then _
                    translation.genericC.header.headerTypeAliases( _
                        typedefAliasIndex).alignmentValue = .typedefAlignment
            End If
        End With
        translation.genericC.header.recordPlans(entryIndex) = plan
    Next

    ' FBFrog names anonymous aggregate layouts after direct objects and
    ' function results that expose them. Keep the stable synthetic name too,
    ' then add aliases in FreeBASIC's separate type namespace.
    For entryIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(entryIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               .recordTag <> "" OrElse .isTypedef <> 0 OrElse _
               .recordTail = "" OrElse .unsupported <> 0 OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION AndAlso _
                .recordKind <> C2FB_RECORD_ENUM) Then Continue For
            If entryIndex > UBound(translation.genericC.header.recordPlans) Then _
                ReportError("generic record plan table is incomplete")
            If translation.genericC.header.recordPlans(entryIndex).isPrepared = 0 OrElse _
               translation.genericC.header.recordPlans(entryIndex).sourceDeclarationIndex <> _
                   entryIndex Then _
                ReportError("generic record plan does not match its source declaration")
            Dim plan As C2fbGenericRecordPlanModel = _
                translation.genericC.header.recordPlans(entryIndex)
            If plan.isSupported = 0 OrElse plan.isOpaqueEmpty <> 0 OrElse _
               plan.freeBasicName = "" Then Continue For

            Dim tailParts() As String
            Dim tailNames() As String
            Dim tailBindingOrders() As String
            Dim tailPartCount As Long
            If ParseGenericRecordTypedefTail( _
                .recordTail, tailParts(), tailNames(), tailBindingOrders(), _
                tailPartCount) = 0 Then Continue For
            For tailPartIndex As Long = 0 To tailPartCount - 1
                Dim bindingOrder As String = tailBindingOrders(tailPartIndex)
                If InStr(bindingOrder, "P") <> 0 OrElse _
                   InStr(bindingOrder, "A") <> 0 Then Continue For
                Dim renameNamespace As C2fbSymbolRenameNamespace = _
                    C2FB_SYMBOL_RENAME_GENERAL
                If Left(bindingOrder, 1) = "F" Then _
                    renameNamespace = C2FB_SYMBOL_RENAME_PROCEDURE
                Dim useSiteTypeName As String = _
                    GenericFreeBasicFunctionNameInContext( _
                        translation, tailNames(tailPartIndex), outputNames(), _
                        outputNameCount, renameNamespace)
                Do
                    Dim typeNameConflict As Long = 0
                    For typeNameIndex As Long = 0 To typeNameCount - 1
                        If LCase(typeNames(typeNameIndex)) = _
                           LCase(useSiteTypeName) Then
                            typeNameConflict = -1
                            Exit For
                        End If
                    Next
                    If typeNameConflict = 0 Then Exit Do
                    useSiteTypeName &= "_"
                Loop
                If typeNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                    ReportError("generic header exceeds the configured typedef limit")
                If typeNameCount > UBound(typeNames) Then _
                    ReDim Preserve typeNames(0 To UBound(typeNames) * 2 + 1)
                typeNames(typeNameCount) = useSiteTypeName
                typeNameCount += 1

                With translation.genericC.header.recordPlans(entryIndex)
                    If .useSiteTypeAliasCount = 0 Then
                        ReDim .useSiteTypeAliases(0 To 3)
                    ElseIf .useSiteTypeAliasCount > _
                           UBound(.useSiteTypeAliases) Then
                        ReDim Preserve .useSiteTypeAliases( _
                            0 To UBound(.useSiteTypeAliases) * 2 + 1)
                    End If
                    .useSiteTypeAliases(.useSiteTypeAliasCount) = useSiteTypeName
                    .useSiteTypeAliasCount += 1
                End With
            Next
        End With
    Next
    RebuildGenericHeaderTypeAliasIndex(translation.genericC.header)
    Return -1
End Function

Private Sub RequireGenericRecordPlan( _
    ByRef translation As C2fbTranslationContext, ByVal declarationIndex As Long _
)
    If declarationIndex < 0 OrElse declarationIndex >= translation.sourceUnit.declarationCount Then _
        ReportError("generic record plan references an invalid declaration")
    If declarationIndex > UBound(translation.genericC.header.recordPlans) Then _
        ReportError("generic record plan table is incomplete")
    Dim plan As C2fbGenericRecordPlanModel = _
        translation.genericC.header.recordPlans(declarationIndex)
    If plan.isPrepared = 0 OrElse _
       plan.sourceDeclarationIndex <> declarationIndex Then _
        ReportError("generic record plan does not match its source declaration")
End Sub

Private Sub MarkGenericHeaderRecordOpaqueEmpty( _
    ByRef translation As C2fbTranslationContext, _
    ByRef declaration As C2fbDeclarationModel, _
    ByVal declarationIndex As Long, _
    ByRef plan As C2fbGenericRecordPlanModel _
)
    plan.isOpaqueEmpty = -1
    plan.implementationName = "Any"
    If declaration.recordTag <> "" Then
        Dim tagAliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, declaration.recordTag, -1)
        If tagAliasIndex >= 0 Then _
            translation.genericC.header.headerTypeAliases(tagAliasIndex).baseType = "Any"
    End If
    If declaration.recordAlias <> "" Then
        Dim ordinaryAliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, declaration.recordAlias, 0)
        If ordinaryAliasIndex >= 0 Then
            If declaration.recordTag = "" OrElse _
               declaration.recordAlias = declaration.recordTag Then
                translation.genericC.header.headerTypeAliases(ordinaryAliasIndex).baseType = "Any"
            Else
                translation.genericC.header.headerTypeAliases(ordinaryAliasIndex).baseType = _
                    plan.freeBasicName
            End If
        End If
    End If
    translation.genericC.header.recordPlans(declarationIndex) = plan
End Sub

Private Function GenericRecordFieldDependsOnUnsupportedLayout( _
    ByRef translation As C2fbTranslationContext, _
    ByVal fieldType As String _
) As Long
    fieldType = Trim(fieldType)
    If Left(LCase(fieldType), Len("const ")) = "const " Then _
        fieldType = Trim(Mid(fieldType, Len("const ") + 1))
    If fieldType = "" OrElse InStr(LCase(fieldType), " ptr") <> 0 Then Return 0

    For dependencyIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(dependencyIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) Then Continue For
            Dim dependencyPlan As C2fbGenericRecordPlanModel = _
                translation.genericC.header.recordPlans(dependencyIndex)
            If dependencyPlan.isPrepared = 0 OrElse _
               dependencyPlan.isSupported <> 0 OrElse _
               dependencyPlan.isExcluded <> 0 OrElse _
               dependencyPlan.isOpaqueEmpty <> 0 Then Continue For
            If LCase(fieldType) = LCase(dependencyPlan.freeBasicName) OrElse _
               LCase(fieldType) = LCase(dependencyPlan.aliasFreeBasicName) OrElse _
               LCase(fieldType) = LCase(.recordTag) OrElse _
               LCase(fieldType) = LCase(.recordAlias) Then Return -1
        End With
    Next
    Return 0
End Function

Private Sub PropagateUnsupportedGenericRecordLayouts( _
    ByRef translation As C2fbTranslationContext _
)
    Dim changed As Long
    Do
        changed = 0
        For entryIndex As Long = 0 To _
            translation.sourceUnit.declarationCount - 1
            With translation.sourceUnit.declarations(entryIndex)
                If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
                   (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                    .recordKind <> C2FB_RECORD_UNION) Then Continue For
                Dim plan As C2fbGenericRecordPlanModel = _
                    translation.genericC.header.recordPlans(entryIndex)
                If plan.isPrepared = 0 OrElse plan.isSupported = 0 OrElse _
                   plan.isExcluded <> 0 OrElse plan.isOpaqueEmpty <> 0 OrElse _
                   plan.bindingReady = 0 Then Continue For

                Dim hasUnsupportedDependency As Long = 0
                For itemIndex As Long = 0 To plan.binding.itemCount - 1
                    With plan.binding.items(itemIndex)
                        If .kind <> C2FB_RECORD_BINDING_ITEM_FIELD AndAlso _
                           .kind <> C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY Then _
                            Continue For
                        If GenericRecordFieldDependsOnUnsupportedLayout( _
                            translation, .fieldType) <> 0 Then
                            hasUnsupportedDependency = -1
                            Exit For
                        End If
                    End With
                Next
                If hasUnsupportedDependency = 0 Then Continue For

                plan.isSupported = 0
                plan.bindingReady = 0
                translation.genericC.header.recordPlans(entryIndex) = plan
                If .recordTag <> "" Then _
                    RemoveGenericHeaderTypeAliasInHeader( _
                        translation.genericC.header, .recordTag, 0, -1)
                If .recordAlias <> "" Then _
                    RemoveGenericHeaderTypeAliasInHeader( _
                        translation.genericC.header, .recordAlias, 0, 0)
                changed = -1
            End With
        Next
    Loop While changed <> 0
End Sub

Private Sub ValidateGenericHeaderRecordLayouts( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, outputNames() As String, _
    ByRef outputNameCount As Long _
)
    For entryIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(entryIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD Then Continue For
            RequireGenericRecordPlan(translation, entryIndex)
            If translation.genericC.header.recordPlans(entryIndex).isExcluded <> 0 Then _
                Continue For
            If .unsupported <> 0 OrElse _
               .recordKind = C2FB_RECORD_ENUM Then Continue For
            If translation.genericC.header.recordPlans(entryIndex).isOpaqueEmpty <> 0 Then _
                Continue For
            Dim fields() As GenericRecordField
            Dim fieldCount As Long
            Dim nestedBindingCountBefore As Long = _
                translation.genericC.header.recordPlans(entryIndex).nestedBindingCount
            Dim nameCountBeforeRecord As Long = outputNameCount
            With translation.genericC.header.recordPlans(entryIndex)
                ReDim .nestedBindings(0 To 3)
                .nestedBindingCount = 0
                .nestedBindingSequence = 0
                .unsupportedFieldName = ""
            End With
            If ParseGenericRecordFields( _
                translation, catalog, translation.sourceUnit.declarations(entryIndex), _
                translation.genericC.header.recordPlans(entryIndex), _
                outputNames(), outputNameCount, fields(), fieldCount, _
                .recordTag, .recordAlias) = 0 Then
                outputNameCount = nameCountBeforeRecord
                translation.genericC.header.recordPlans(entryIndex).nestedBindingCount = _
                    nestedBindingCountBefore
                translation.genericC.header.recordPlans(entryIndex).isSupported = 0
                If .recordTag <> "" Then _
                    RemoveGenericHeaderTypeAliasInHeader( _
                        translation.genericC.header, .recordTag, 0, -1)
                If .recordAlias <> "" Then _
                    RemoveGenericHeaderTypeAliasInHeader( _
                        translation.genericC.header, .recordAlias, 0, 0)
                Continue For
            End If

            For fieldIndex As Long = 0 To fieldCount - 1
                If fields(fieldIndex).itemKind = _
                       C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY AndAlso _
                   fields(fieldIndex).zeroArrayStorageName <> "" Then
                    translation.genericC.header.recordPlans(entryIndex).hasNonByteFlexibleTail = -1
                    Exit For
                End If
            Next

            If fieldCount = 0 Then
                MarkGenericHeaderRecordOpaqueEmpty( _
                    translation, translation.sourceUnit.declarations(entryIndex), _
                    entryIndex, translation.genericC.header.recordPlans(entryIndex))
                Continue For
            End If

            Dim recordBinding As C2fbRecordBindingModel
            recordBinding.freeBasicName = _
                translation.genericC.header.recordPlans(entryIndex).implementationName
            recordBinding.isUnion = CInt(.recordKind = C2FB_RECORD_UNION) * -1
            recordBinding.isPacked = .isPacked
            recordBinding.packValue = .packValue
            If recordBinding.packValue = 0 AndAlso .isPacked = 0 Then _
                recordBinding.packValue = GenericRecordOnlyPackedTopLevelAggregate( _
                    fields(), fieldCount)
            recordBinding.alignmentValue = .recordAlignment
            recordBinding.itemCount = fieldCount
            If fieldCount > 0 Then
                ReDim recordBinding.items(0 To fieldCount - 1)
                For itemIndex As Long = 0 To fieldCount - 1
                    recordBinding.items(itemIndex).kind = fields(itemIndex).itemKind
                    recordBinding.items(itemIndex).isUnion = fields(itemIndex).isUnion
                    recordBinding.items(itemIndex).packValue = fields(itemIndex).packValue
                    recordBinding.items(itemIndex).isBitField = fields(itemIndex).isBitField
                    recordBinding.items(itemIndex).isArraySizeHinted = _
                        fields(itemIndex).isArraySizeHinted
                    recordBinding.items(itemIndex).bitWidth = fields(itemIndex).bitWidth
                    recordBinding.items(itemIndex).name = fields(itemIndex).name
                    recordBinding.items(itemIndex).sourceName = _
                        fields(itemIndex).sourceName
                    recordBinding.items(itemIndex).fieldType = fields(itemIndex).fieldType
                    recordBinding.items(itemIndex).alignmentStorageType = _
                        fields(itemIndex).alignmentStorageType
                    recordBinding.items(itemIndex).arrayCount = fields(itemIndex).arrayCount
                    recordBinding.items(itemIndex).arrayBounds = fields(itemIndex).arrayBounds
                    recordBinding.items(itemIndex).zeroArrayAccessorName = _
                        fields(itemIndex).zeroArrayAccessorName
                    recordBinding.items(itemIndex).zeroArrayStorageName = _
                        fields(itemIndex).zeroArrayStorageName
                    recordBinding.items(itemIndex).zeroArrayPreviousFieldName = _
                        fields(itemIndex).zeroArrayPreviousFieldName
                    recordBinding.items(itemIndex).zeroArrayPreviousArrayCount = _
                        fields(itemIndex).zeroArrayPreviousArrayCount
                Next
            End If
            Dim hasNestedAggregate As Long = _
                GenericRecordBindingHasNestedAggregate( _
                    translation, recordBinding)
            Dim naturalAlignment As Long = _
                GenericRecordBindingNaturalAlignmentBytes( _
                    translation, recordBinding)
            If naturalAlignment <= 0 AndAlso hasNestedAggregate <> 0 Then
                Dim pointerWidth As Long = GenericPreprocessorTypeWidthInBits( _
                    translation, "__SIZEOF_POINTER__", 4)
                If pointerWidth > 0 AndAlso pointerWidth Mod 8 = 0 Then _
                    naturalAlignment = pointerWidth \ 8
            End If
            Dim aliasNaturalAlignment As Long = naturalAlignment
            If recordBinding.alignmentValue > aliasNaturalAlignment Then _
                aliasNaturalAlignment = recordBinding.alignmentValue
            ' Record-level alignment must propagate when a later record embeds this tag.
            recordBinding.naturalAlignmentValue = aliasNaturalAlignment
            Dim naturalAliasIndex As Long = _
                GenericHeaderTypeAliasIndexByFreeBasicNameInHeader( _
                    translation.genericC.header, _
                    translation.genericC.header.recordPlans(entryIndex).freeBasicName)
            If naturalAliasIndex >= 0 Then _
                translation.genericC.header.headerTypeAliases( _
                    naturalAliasIndex).naturalAlignmentValue = aliasNaturalAlignment
            Dim naturalAliasName As String = _
                translation.genericC.header.recordPlans(entryIndex).aliasFreeBasicName
            If naturalAliasName <> "" Then
                naturalAliasIndex = GenericHeaderTypeAliasIndexByFreeBasicNameInHeader( _
                    translation.genericC.header, naturalAliasName)
                If naturalAliasIndex >= 0 Then _
                    translation.genericC.header.headerTypeAliases( _
                        naturalAliasIndex).naturalAlignmentValue = aliasNaturalAlignment
            End If
            If naturalAlignment > 0 AndAlso _
               recordBinding.alignmentValue <= naturalAlignment Then _
                recordBinding.alignmentValue = 0
            If recordBinding.packValue = 0 AndAlso _
               recordBinding.isPacked = 0 AndAlso _
               naturalAlignment > 0 AndAlso _
               hasNestedAggregate <> 0 Then _
                recordBinding.packValue = naturalAlignment
            translation.genericC.header.recordPlans(entryIndex).binding = recordBinding
            translation.genericC.header.recordPlans(entryIndex).bindingReady = -1
        End With
    Next
    PropagateUnsupportedGenericRecordLayouts(translation)
End Sub

Private Sub WriteGenericHeaderRecordAliases( _
    ByRef translation As C2fbTranslationContext, ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    ' Type aliases can refer forward to a later UDT. Emit these names before
    ' record bodies so recursive pointers have a stable FreeBASIC type.
    For entryIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(entryIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD Then Continue For
            If .removeFromGenericHeader <> 0 Then Continue For
            If GenericSourceIncludedInPolicy( _
                translation.genericC.policy, .sourceSpan.startLocation.path) = 0 Then _
                Continue For
            RequireGenericRecordPlan(translation, entryIndex)
            Dim plan As C2fbGenericRecordPlanModel = _
                translation.genericC.header.recordPlans(entryIndex)
            If plan.isSupported = 0 OrElse plan.freeBasicName = "" Then Continue For
            Dim typeAlias As C2fbTypeAliasBindingModel
            Dim tagAliasIndex As Long = -1
            If .recordTag <> "" Then
                tagAliasIndex = GenericHeaderTypeAliasIndexInHeader( _
                    translation.genericC.header, .recordTag, -1)
            End If
            If tagAliasIndex < 0 OrElse _
               translation.genericC.header.headerTypeAliases(tagAliasIndex).isForward = 0 Then
                Select Case .recordKind
                Case C2FB_RECORD_STRUCT, C2FB_RECORD_UNION
                    typeAlias.freeBasicName = plan.freeBasicName
                    typeAlias.targetType = plan.implementationName
                    typeAlias.alignmentValue = 0
                    WriteC2fbTypeAlias( _
                        outputFile, typeAlias, plan.ifndefGuardName, plan.undefBeforeName)
                Case C2FB_RECORD_ENUM
                    typeAlias.freeBasicName = plan.freeBasicName
                    typeAlias.targetType = "Long"
                    typeAlias.alignmentValue = 0
                    WriteC2fbTypeAlias( _
                        outputFile, typeAlias, plan.ifndefGuardName, plan.undefBeforeName)
                End Select
            End If
            If .recordTag <> "" Then
                If tagAliasIndex < 0 OrElse _
                   translation.genericC.header.headerTypeAliases(tagAliasIndex).isForward = 0 Then _
                    MarkGenericHeaderTypeAliasEmittedInHeader( _
                        translation.genericC.header, .recordTag, -1)
            ElseIf .recordAlias <> "" Then
                MarkGenericHeaderTypeAliasEmittedInHeader( _
                    translation.genericC.header, .recordAlias, 0)
            End If
            If .recordTag <> "" AndAlso .recordAlias = .recordTag Then
                Dim sameNameAliasIndex As Long = _
                    GenericHeaderTypeAliasIndexInHeader( _
                        translation.genericC.header, .recordAlias, 0)
                If sameNameAliasIndex >= 0 AndAlso _
                   translation.genericC.header.headerTypeAliases( _
                       sameNameAliasIndex).isForward = 0 Then _
                    MarkGenericHeaderTypeAliasEmittedInHeader( _
                        translation.genericC.header, .recordAlias, 0)
            End If
            If .recordAlias <> "" AndAlso plan.aliasFreeBasicName = "" Then
                Dim sharedOrdinaryAliasIndex As Long = _
                    GenericHeaderTypeAliasIndexInHeader( _
                        translation.genericC.header, .recordAlias, 0)
                If sharedOrdinaryAliasIndex >= 0 Then _
                    If translation.genericC.header.headerTypeAliases( _
                        sharedOrdinaryAliasIndex).isForward = 0 Then _
                        MarkGenericHeaderTypeAliasEmittedInHeader( _
                            translation.genericC.header, .recordAlias, 0)
            End If
            If plan.aliasFreeBasicName <> "" Then
                Dim ordinaryAliasIndex As Long = _
                    GenericHeaderTypeAliasIndexInHeader( _
                        translation.genericC.header, .recordAlias, 0)
                If ordinaryAliasIndex < 0 OrElse _
                   translation.genericC.header.headerTypeAliases(ordinaryAliasIndex).isForward = 0 Then
                    typeAlias.freeBasicName = plan.aliasFreeBasicName
                    typeAlias.targetType = plan.freeBasicName
                    typeAlias.alignmentValue = .typedefAlignment
                    WriteC2fbTypeAlias( _
                        outputFile, typeAlias, plan.ifndefGuardName, "")
                    MarkGenericHeaderTypeAliasEmittedInHeader( _
                        translation.genericC.header, .recordAlias, 0)
                End If
            End If
            For useSiteAliasIndex As Long = 0 To plan.useSiteTypeAliasCount - 1
                typeAlias.freeBasicName = _
                    plan.useSiteTypeAliases(useSiteAliasIndex)
                typeAlias.targetType = plan.freeBasicName
                typeAlias.alignmentValue = 0
                WriteC2fbTypeAlias( _
                    outputFile, typeAlias, plan.ifndefGuardName, "")
            Next
        End With
    Next
    If translation.sourceUnit.declarationCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

/' ------------------------------------------------------------------------- '/
/' Record field validation and ABI layout emission                          '/
/' ------------------------------------------------------------------------- '/

Private Function GenericFieldHasUnsupportedAttribute(ByVal declaration As String) As Long
    Dim position As Long = 1
    While position <= Len(declaration)
        If IsIdentifierStart(Asc(declaration, position)) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(declaration) AndAlso _
                  IsIdentifierPart(Asc(declaration, position)) <> 0
                position += 1
            Wend
            Dim token As String = LCase(Mid(declaration, tokenStart, _
                                            position - tokenStart))
            Select Case token
            Case "__declspec"
                Return -1
            Case "__attribute__"
                Dim groupPosition As Long = position
                While groupPosition <= Len(declaration) AndAlso _
                      IsSpaceByte(Asc(declaration, groupPosition)) <> 0
                    groupPosition += 1
                Wend
                If groupPosition > Len(declaration) OrElse _
                   Asc(declaration, groupPosition) <> Asc("(") Then Return -1

                Dim attributeGroupStart As Long = groupPosition
                If ScanSimpleExpressionGroup( _
                    declaration, groupPosition, Asc("("), Asc(")")) = 0 Then _
                    Return -1

                Dim attributeTokens() As String
                Dim attributeTokenCount As Long
                TokenizeCDeclaration( _
                    Mid(declaration, attributeGroupStart, _
                        groupPosition - attributeGroupStart), _
                    attributeTokens(), attributeTokenCount)
                For attributeIndex As Long = 0 To attributeTokenCount - 1
                    Select Case LCase(attributeTokens(attributeIndex))
                    Case "(", ")", ",", "nonstring", "__nonstring__"
                        ' GCC uses nonstring only for diagnostics; it does not
                        ' change the field's storage or ABI layout.
                    Case Else
                        Return -1
                    End Select
                Next
                position = groupPosition
            End Select
        Else
            position += 1
        End If
    Wend
    Return 0
End Function

Private Function GenericTokensToText( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long _
) As String
    Dim result As String
    For tokenIndex As Long = firstToken To lastToken
        If result <> "" Then result &= " "
        result &= tokens(tokenIndex)
    Next
    Return result
End Function

Declare Function TranslateGenericRecordFieldWithTokens( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceDeclarator As String, ByVal declaration As String, _
    tokens() As String, ByVal tokenCount As Long, _
    ByRef commonType As String, ByRef commonTypeTokenCount As Long, _
    ByVal firstDeclarator As Long, _
    ByVal ownerTag As String, ByVal ownerAlias As String, _
    ByRef recordField As GenericRecordField _
) As Long

Private Function TranslateGenericRecordField( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceDeclarator As String, ByRef commonType As String, _
    ByVal firstDeclarator As Long, ByVal ownerTag As String, _
    ByVal ownerAlias As String, ByRef recordField As GenericRecordField _
) As Long
    If GenericFieldHasUnsupportedAttribute(sourceDeclarator) <> 0 Then Return 0
    Dim declaration As String = StripCFunctionAttributes(sourceDeclarator)
    If firstDeclarator = 0 Then declaration = commonType & " " & declaration

    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(declaration, tokens(), tokenCount)
    Dim commonTypeTokenCount As Long = 0
    Return TranslateGenericRecordFieldWithTokens( _
        translation, catalog, sourceDeclarator, declaration, tokens(), tokenCount, _
        commonType, commonTypeTokenCount, firstDeclarator, ownerTag, ownerAlias, recordField)
End Function

Private Function GenericPreprocessorTypeWidthInBits( _
    ByRef translation As C2fbTranslationContext, ByVal macroName As String, _
    ByVal fallbackBytes As Long _
) As Long
    For macroIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse .definition.sourceName <> macroName Then Continue For
            Dim byteCount As Long = Val(Trim(.definition.rawValue))
            If byteCount <= 0 OrElse byteCount > 8 Then Return 0
            Return byteCount * 8
        End With
    Next
    Return fallbackBytes * 8
End Function

Private Function GenericRecordBitFieldStorageWidthInBits( _
    ByRef translation As C2fbTranslationContext, ByVal freeBasicType As String _
) As Long
    If Left(freeBasicType, 6) = "Const " Then freeBasicType = Mid(freeBasicType, 7)
    Dim aliasStorageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, freeBasicType, 0)
    If aliasStorageType <> "" Then freeBasicType = aliasStorageType

    Select Case LCase(freeBasicType)
    Case "byte", "ubyte", "boolean": Return 8
    Case "short", "ushort": Return 16
    Case "long", "ulong": Return 32
    Case "clong", "culong"
        Return GenericPreprocessorTypeWidthInBits( _
            translation, "__SIZEOF_LONG__", 0)
    Case "longint", "ulongint"
        If GenericPreprocessorTypeWidthInBits( _
            translation, "__SIZEOF_POINTER__", 4) < 64 Then Return 0
        Return 64
    Case Else
        Return 0
    End Select
End Function

Private Function GenericRecordValueFieldType( _
    ByRef resolvedType As C2fbResolvedTypeModel _
) As String
    Dim freeBasicType As String = resolvedType.freeBasicType
    If resolvedType.isConst <> 0 AndAlso resolvedType.pointerCount = 0 AndAlso _
       Left(freeBasicType, 6) <> "Const " Then _
        freeBasicType = "Const " & freeBasicType
    Return freeBasicType
End Function

Private Function ResolveGenericRecordCallbackArrayTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, tokens() As String, _
    ByVal tokenCount As Long, ByVal sourceName As String, _
    ByRef callbackResult As C2fbCallbackTypeResultModel, _
    ByVal typeMappingKind As C2fbTypeMappingKind _
) As Long
    If tokenCount <= 0 OrElse sourceName = "" Then Return 0
    Dim lastToken As Long = tokenCount - 1
    If tokens(lastToken) = ";" Then lastToken -= 1

    For nameToken As Long = 0 To lastToken - 1
        If tokens(nameToken) <> sourceName OrElse _
           tokens(nameToken + 1) <> "[" Then Continue For

        ' Remove every array suffix that belongs to this declarator while
        ' keeping its function-pointer signature intact for the callback parser.
        Dim arrayClose As Long = nameToken + 1
        Do While arrayClose <= lastToken AndAlso tokens(arrayClose) = "["
            Dim nesting As Long = 1
            Dim closeToken As Long = arrayClose + 1
            While closeToken <= lastToken AndAlso nesting > 0
                If tokens(closeToken) = "[" Then
                    nesting += 1
                ElseIf tokens(closeToken) = "]" Then
                    nesting -= 1
                End If
                If nesting > 0 Then closeToken += 1
            Wend
            If nesting <> 0 Then Return 0
            arrayClose = closeToken + 1
        Loop

        Dim callbackTokens() As String
        ReDim callbackTokens(0 To lastToken - 1)
        Dim callbackTokenCount As Long = 0
        For tokenIndex As Long = 0 To lastToken
            If tokenIndex = nameToken Then
                callbackTokens(callbackTokenCount) = tokens(tokenIndex)
                callbackTokenCount += 1
                tokenIndex = arrayClose - 1
                Continue For
            End If
            callbackTokens(callbackTokenCount) = tokens(tokenIndex)
            callbackTokenCount += 1
        Next
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, callbackTokens(), 0, _
            callbackTokenCount - 1, callbackResult, 0, typeMappingKind)
        Return -1
    Next
    Return 0
End Function

Private Function TranslateGenericRecordFieldWithTokens( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceDeclarator As String, ByVal declaration As String, _
    tokens() As String, ByVal tokenCount As Long, _
    ByRef commonType As String, ByRef commonTypeTokenCount As Long, _
    ByVal firstDeclarator As Long, _
    ByVal ownerTag As String, ByVal ownerAlias As String, _
    ByRef recordField As GenericRecordField _
) As Long
    If GenericFieldHasUnsupportedAttribute(sourceDeclarator) <> 0 Then Return 0
    If tokenCount < 2 OrElse tokenCount >= MAX_TYPE_WORDS Then Return 0
    Dim anonymousEnumBody As String
    Dim hasAnonymousEnumType As Long = _
        GenericAnonymousEnumFieldTypeBody( _
            translation, declaration, anonymousEnumBody)
    Dim savedCommonType As String = commonType
    Dim savedCommonTypeTokenCount As Long = commonTypeTokenCount
    If hasAnonymousEnumType <> 0 Then
        Dim enumStart As Long
        Dim enumEnd As Long
        If GenericFindAnonymousEnumBody( _
            declaration, anonymousEnumBody, enumStart, enumEnd) = 0 Then Return 0
        If firstDeclarator <> 0 Then
            savedCommonType = Trim(Left(declaration, enumEnd))
            Dim savedTypeTokens() As String
            TokenizeCDeclaration( _
                savedCommonType, savedTypeTokens(), savedCommonTypeTokenCount)
            If savedCommonTypeTokenCount = 0 Then Return 0
        End If
        Dim normalizedDeclaration As String = _
            Left(declaration, enumStart - 1) & "int" & _
            Mid(declaration, enumEnd + 1)
        Dim normalizedTokens() As String
        Dim normalizedTokenCount As Long
        TokenizeCDeclaration( _
            normalizedDeclaration, normalizedTokens(), normalizedTokenCount)
        If normalizedTokenCount < 2 OrElse _
           normalizedTokenCount >= MAX_TYPE_WORDS Then Return 0
        ReDim tokens(0 To normalizedTokenCount - 1)
        For normalizedTokenIndex As Long = 0 To normalizedTokenCount - 1
            tokens(normalizedTokenIndex) = normalizedTokens(normalizedTokenIndex)
        Next
        declaration = normalizedDeclaration
        tokenCount = normalizedTokenCount
        commonType = "int"
        commonTypeTokenCount = 1
    End If
    Dim bitfieldColonIndex As Long = -1
    Dim parenthesisDepth As Long = 0
    Dim bracketDepth As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case tokens(tokenIndex)
        Case "(": parenthesisDepth += 1
        Case ")": If parenthesisDepth > 0 Then parenthesisDepth -= 1
        Case "[": bracketDepth += 1
        Case "]": If bracketDepth > 0 Then bracketDepth -= 1
        Case ":"
            If parenthesisDepth <> 0 OrElse bracketDepth <> 0 Then Continue For
            If bitfieldColonIndex >= 0 Then Return 0
            bitfieldColonIndex = tokenIndex
        End Select
    Next
    Dim declaratorTokenCount As Long = tokenCount
    Dim bitfieldWidth As Long = 0
    If bitfieldColonIndex >= 0 Then
        If bitfieldColonIndex <= 1 OrElse bitfieldColonIndex >= tokenCount - 1 Then _
            Return 0
        Dim sourceColonPosition As Long = InStr(sourceDeclarator, ":")
        If sourceColonPosition = 0 OrElse EvaluateSimpleArrayBound( _
            Trim(Mid(sourceDeclarator, sourceColonPosition + 1)), _
            bitfieldWidth, 64) = 0 Then Return 0
        declaratorTokenCount = bitfieldColonIndex
    End If

    Dim fieldName As String
    Dim bindingOrder As String
    Dim nameTokenIndex As Long = -1
    Dim functionOpenToken As Long = -1
    Dim typeStart As Long = -1
    For declaratorStart As Long = 1 To declaratorTokenCount - 1
        If IsCFunctionReturnTypePrefix(tokens(), 0, declaratorStart - 1) = 0 Then Continue For
        Dim position As Long = declaratorStart
        Dim candidate As C2fbDeclaratorModel
        If ParseCDeclaratorModel( _
            tokens(), position, declaratorTokenCount - 1, candidate) = 0 Then Continue For
        If position <> declaratorTokenCount Then Continue For
        If IsIdentifierToken(candidate.name) = 0 Then Continue For
        fieldName = candidate.name
        bindingOrder = candidate.bindingOrder
        nameTokenIndex = candidate.nameTokenIndex
        functionOpenToken = candidate.firstFunctionOpenToken
        typeStart = declaratorStart
        ' Prefer the longest valid type prefix. A keyword such as "unsigned"
        ' can itself look like a typedef name before the rest of a multiword
        ' type is considered, especially before a function-pointer declarator.
    Next
    If typeStart < 0 OrElse nameTokenIndex < 0 Then Return 0
    recordField.name = fieldName
    recordField.sourceName = fieldName
    If firstDeclarator <> 0 Then
        commonType = GenericTokensToText(tokens(), 0, typeStart - 1)
        commonTypeTokenCount = typeStart
    End If
    If commonType = "" Then Return 0
    ' FreeBASIC has no C complex scalar ABI type. A plain complex value or a
    ' callback signature containing one cannot be laid out or called safely;
    ' opaque data pointers remain representable as pointer-sized fields.
    Dim hasComplexTypeSpecifier As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case LCase(tokens(tokenIndex))
        Case "_complex", "_imaginary", "__complex", "__complex__", _
             "__imaginary", "__imaginary__"
            hasComplexTypeSpecifier = -1
            Exit For
        End Select
    Next
    If hasComplexTypeSpecifier <> 0 AndAlso _
       (InStr(bindingOrder, "P") = 0 OrElse InStr(bindingOrder, "F") <> 0) Then _
        Return 0

    Dim arrayTypeAliasIndex As Long = -1
    Dim callbackResult As C2fbCallbackTypeResultModel
    ' An inline anonymous enum member is an integer object, not a callback.
    If hasAnonymousEnumType <> 0 Then
        callbackResult.status = C2FB_CALLBACK_TYPE_NOT_CALLBACK
    Else
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, tokens(), 0, declaratorTokenCount - 1, _
            callbackResult, 0, C2FB_TYPE_MAPPING_GENERIC_HEADER)
    End If
    If hasAnonymousEnumType = 0 AndAlso _
       callbackResult.status <> C2FB_CALLBACK_TYPE_CONVERTED AndAlso _
       Len(bindingOrder) > 0 AndAlso InStr(bindingOrder, "A") <> 0 Then _
        ResolveGenericRecordCallbackArrayTypeInContext( _
            translation, catalog, tokens(), declaratorTokenCount, _
            fieldName, callbackResult, C2FB_TYPE_MAPPING_GENERIC_HEADER)
    If callbackResult.status = C2FB_CALLBACK_TYPE_UNSUPPORTED Then Return 0
    If callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED AndAlso _
       callbackResult.callbackName = fieldName Then
        If callbackResult.pointerDepth > 1 Then Return 0
        recordField.fieldType = CBodyCallbackDeclarationInContext( _
            translation, callbackResult.freeBasicType)
        If recordField.fieldType = "" Then Return 0
        Dim callbackArrayDimensions As Long = 0
        For bindingIndex As Long = 1 To Len(bindingOrder)
            If Mid(bindingOrder, bindingIndex, 1) = "A" Then _
                callbackArrayDimensions += 1
        Next
        If callbackArrayDimensions > 0 Then
            If callbackArrayDimensions > MAX_GENERIC_ARRAY_RANK Then Return 0
            Dim identifierPosition As Long = _
                GenericLastIdentifierPosition(declaration, fieldName)
            Dim firstArrayDimensionCount As Long
            Dim unsizedArray As Long
            If identifierPosition = 0 OrElse _
               ParseGenericArrayBoundsInDeclaration( _
                translation, declaration, identifierPosition + Len(fieldName), _
                callbackArrayDimensions, recordField.arrayBounds, _
                firstArrayDimensionCount, recordField.arrayCount, _
                unsizedArray, -1, -1) = 0 Then Return 0
            If unsizedArray <> 0 OrElse recordField.arrayCount = 0 Then
                recordField.arrayBounds = ""
                recordField.arrayCount = 0
                recordField.isZeroLengthArray = -1
                If callbackArrayDimensions <> 1 Then Return 0
            End If
        End If
        For pointerIndex As Long = 2 To callbackResult.pointerDepth
            recordField.fieldType &= " Ptr"
        Next
    Else
        If Len(bindingOrder) > 0 AndAlso Left(bindingOrder, 1) = "F" Then Return 0
        Dim baseTokens() As String
        Dim baseTokenCount As Long
        Dim commonTypeIsFunctionType As Long = 0
        Dim typeTextForResolution As String = commonType
        ' The target's default C enum representation uses int-sized storage
        ' when all enumerators fit int. The constants are indexed separately.
        If hasAnonymousEnumType <> 0 Then typeTextForResolution = "int"
        TokenizeCDeclaration(typeTextForResolution, baseTokens(), baseTokenCount)
        If baseTokenCount = 0 Then Return 0
        For tokenIndex As Long = 0 To baseTokenCount - 1
            Dim callbackAliasIndex As Long = _
                GenericHeaderTypeAliasIndexInHeader( _
                    translation.genericC.header, baseTokens(tokenIndex), 0)
            If callbackAliasIndex >= 0 AndAlso _
               translation.genericC.header.headerTypeAliases(callbackAliasIndex).isFunction <> 0 Then
                commonTypeIsFunctionType = -1
                Exit For
            End If
        Next

        For tokenIndex As Long = 0 To baseTokenCount - 1
            Dim candidateAlias As Long = _
                GenericHeaderTypeAliasIndexInHeader( _
                    translation.genericC.header, baseTokens(tokenIndex), 0)
            If candidateAlias >= 0 AndAlso _
               translation.genericC.header.headerTypeAliases(candidateAlias).isArray <> 0 Then
                arrayTypeAliasIndex = candidateAlias
                Exit For
            End If
        Next

        If arrayTypeAliasIndex >= 0 Then
            Dim pointerLevels As Long = 0
            Dim arrayDimensions As Long = 0
            Dim hasFunctionOperator As Long = 0
            For bindingIndex As Long = 1 To Len(bindingOrder)
                Select Case Mid(bindingOrder, bindingIndex, 1)
                Case "P": pointerLevels += 1
                Case "A": arrayDimensions += 1
                Case "F": hasFunctionOperator = -1
                End Select
            Next
            If hasFunctionOperator <> 0 Then Return 0
            If bindingOrder = "" Then
                recordField.fieldType = _
                    translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayElementType
                recordField.arrayCount = _
                    translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayCount
                recordField.arrayBounds = _
                    translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayBounds
                If recordField.arrayCount = 0 Then _
                    recordField.isZeroLengthArray = -1
            ElseIf Left(bindingOrder, 1) = "P" AndAlso pointerLevels > 0 Then
                ' A pointer to an array typedef has pointer-sized storage. Keep
                ' it opaque so BASIC indexing cannot assume the element stride.
                recordField.fieldType = "Any Ptr"
                For pointerIndex As Long = 2 To pointerLevels
                    recordField.fieldType &= " Ptr"
                Next
            ElseIf Left(bindingOrder, 1) = "A" AndAlso _
                   arrayDimensions > 0 AndAlso pointerLevels = 0 Then
                Dim identifierPosition As Long = _
                    GenericLastIdentifierPosition(declaration, fieldName)
                Dim objectBounds As String
                Dim objectFirstCount As Long
                Dim objectElementCount As Long
                Dim objectUnsized As Long
                If identifierPosition = 0 OrElse _
                   ParseGenericArrayBoundsInDeclaration( _
                    translation, declaration, identifierPosition + Len(fieldName), _
                    arrayDimensions, objectBounds, objectFirstCount, _
                    objectElementCount, objectUnsized, -1, -1) = 0 Then Return 0
                Dim typedefElementCount As Long = _
                    translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayCount
                If typedefElementCount <= 0 OrElse objectUnsized <> 0 OrElse _
                   objectElementCount > MAX_GENERIC_ARRAY_COUNT \ typedefElementCount Then _
                    Return 0
                recordField.arrayCount = objectElementCount * typedefElementCount
                recordField.arrayBounds = CombineGenericArrayBounds( _
                    objectBounds, _
                    translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayBounds)
                recordField.fieldType = _
                    translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayElementType
            ElseIf Left(bindingOrder, 1) = "A" AndAlso _
                   arrayDimensions = 1 AndAlso pointerLevels > 0 Then
                Dim openingBracket As Long = InStr(declaration, "[")
                Dim closingBracket As Long = InStr(openingBracket + 1, declaration, "]")
                If openingBracket = 0 OrElse closingBracket = 0 OrElse _
                   (EvaluateSimpleArrayBound(Trim(Mid( _
                       declaration, openingBracket + 1, _
                       closingBracket - openingBracket - 1)), recordField.arrayCount, _
                       MAX_GENERIC_ARRAY_COUNT, -1) = 0 AndAlso _
                    EvaluateGenericHeaderArrayBound(translation, Trim(Mid( _
                        declaration, openingBracket + 1, _
                        closingBracket - openingBracket - 1)), recordField.arrayCount, _
                        MAX_GENERIC_ARRAY_COUNT, -1) = 0) Then Return 0
                If recordField.arrayCount = 0 Then _
                    recordField.isZeroLengthArray = -1
                recordField.fieldType = "Any Ptr"
                For pointerIndex As Long = 2 To pointerLevels
                    recordField.fieldType &= " Ptr"
                Next
            Else
                Return 0
            End If
        ElseIf Len(bindingOrder) > 0 AndAlso Left(bindingOrder, 1) = "A" Then
            Dim arrayDimensions As Long = 0
            Dim pointerElementLevels As Long = 0
            Dim hasFunctionElement As Long = 0
            For bindingIndex As Long = 1 To Len(bindingOrder)
                Select Case Mid(bindingOrder, bindingIndex, 1)
                Case "A": arrayDimensions += 1
                Case "P": pointerElementLevels += 1
                Case "F": hasFunctionElement = -1
                End Select
            Next
            If commonTypeIsFunctionType <> 0 Then hasFunctionElement = -1
            If arrayDimensions > MAX_GENERIC_ARRAY_RANK Then Return 0
            Dim identifierPosition As Long = _
                GenericLastIdentifierPosition(declaration, fieldName)
            Dim firstArrayDimensionCount As Long
            Dim unsizedArray As Long
            If identifierPosition = 0 Then Return 0
            Dim arrayBoundsParsed As Long = ParseGenericArrayBoundsInDeclaration( _
                translation, declaration, identifierPosition + Len(fieldName), _
                arrayDimensions, recordField.arrayBounds, _
                firstArrayDimensionCount, recordField.arrayCount, _
                unsizedArray, -1, -1)
            If arrayBoundsParsed = 0 OrElse _
               (recordField.arrayCount = 0 AndAlso unsizedArray = 0) Then
                ' A caller may supply the exact compiled extent when a fixed
                ' C bound contains sizeof of a record outside this evaluator.
                Dim fixedArraySizeHint As Long = _
                    UseGenericArraySizeOverrideInPolicy( _
                        translation.genericC.policy, fieldName, _
                        ownerTag, ownerAlias)
                If fixedArraySizeHint > 0 Then
                    If fixedArraySizeHint > MAX_GENERIC_ARRAY_COUNT Then Return 0
                    recordField.arrayCount = fixedArraySizeHint
                    recordField.arrayBounds = "0 To " & _
                        Trim(Str(fixedArraySizeHint - 1))
                    recordField.isArraySizeHinted = -1
                    unsizedArray = 0
                ElseIf arrayBoundsParsed = 0 Then
                    Return 0
                End If
            End If
            If unsizedArray <> 0 Then
                Dim arraySizeHint As Long = _
                    UseGenericArraySizeOverrideInPolicy( _
                        translation.genericC.policy, fieldName, _
                        ownerTag, ownerAlias)
                If arraySizeHint > 0 Then
                    recordField.arrayCount = arraySizeHint
                    recordField.arrayBounds = "0 To " & _
                        Trim(Str(arraySizeHint - 1))
                    recordField.isArraySizeHinted = -1
                    unsizedArray = 0
                End If
            End If
            If unsizedArray <> 0 OrElse recordField.arrayCount = 0 Then
                recordField.arrayBounds = ""
                recordField.arrayCount = 0
                recordField.isZeroLengthArray = -1
                If arrayDimensions <> 1 Then Return 0
            End If

            If commonTypeIsFunctionType <> 0 Then
                ' Preserve the alias's own C pointer depth, then resolve any
                ' additional pointer operators on this array element.
                Dim callbackAliasIndex As Long = -1
                For tokenIndex As Long = 0 To baseTokenCount - 1
                    Dim candidateAlias As Long = _
                        GenericHeaderTypeAliasIndexInHeader( _
                            translation.genericC.header, baseTokens(tokenIndex), 0)
                    If candidateAlias >= 0 AndAlso _
                       translation.genericC.header.headerTypeAliases(candidateAlias).isFunction <> 0 Then
                        callbackAliasIndex = candidateAlias
                        Exit For
                    End If
                Next
                If callbackAliasIndex < 0 Then Return 0
                Dim pointerLevels As Long = 0
                For bindingIndex As Long = 1 To Len(bindingOrder)
                    If Mid(bindingOrder, bindingIndex, 1) = "P" Then _
                        pointerLevels += 1
                Next
                If pointerLevels = 0 AndAlso _
                   translation.genericC.header.headerTypeAliases(callbackAliasIndex).functionPointerDepth = 0 Then _
                    Return 0
                If baseTokenCount + pointerLevels >= MAX_TYPE_WORDS Then Return 0
                Dim pointerTokens() As String
                ReDim pointerTokens(0 To MAX_TYPE_WORDS - 1)
                Dim pointerTokenCount As Long = 0
                For tokenIndex As Long = 0 To baseTokenCount - 1
                    AddToken(pointerTokens(), pointerTokenCount, baseTokens(tokenIndex))
                Next
                For pointerIndex As Long = 1 To pointerLevels
                    AddToken(pointerTokens(), pointerTokenCount, "*")
                Next
                Dim resolvedCallbackArrayElement As C2fbResolvedTypeModel
                ResolveC2fbTypeModel(translation, catalog, _
                    pointerTokens(), 0, pointerTokenCount - 1, _
                    resolvedCallbackArrayElement, _
                    C2FB_POINTER_MAPPING_OPAQUE, _
                    C2FB_TYPE_MAPPING_GENERIC_HEADER)
                If resolvedCallbackArrayElement.status <> _
                   C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0
                recordField.fieldType = resolvedCallbackArrayElement.freeBasicType
            ElseIf hasFunctionElement <> 0 Then
                Return 0
            ElseIf pointerElementLevels > 0 Then
                If baseTokenCount + pointerElementLevels >= MAX_TYPE_WORDS Then Return 0
                Dim pointerTokens() As String
                ReDim pointerTokens(0 To MAX_TYPE_WORDS - 1)
                Dim pointerTokenCount As Long = 0
                For tokenIndex As Long = 0 To baseTokenCount - 1
                    AddToken(pointerTokens(), pointerTokenCount, baseTokens(tokenIndex))
                Next
                For pointerIndex As Long = 1 To pointerElementLevels
                    AddToken(pointerTokens(), pointerTokenCount, "*")
                Next
                Dim resolvedArrayPointerType As C2fbResolvedTypeModel
                ResolveC2fbTypeModel(translation, catalog, _
                    pointerTokens(), 0, pointerTokenCount - 1, _
                    resolvedArrayPointerType, C2FB_POINTER_MAPPING_OPAQUE, _
                    C2FB_TYPE_MAPPING_GENERIC_HEADER)
                If resolvedArrayPointerType.status <> _
                   C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0
                recordField.fieldType = resolvedArrayPointerType.freeBasicType
            Else
                Dim resolvedArrayFieldType As C2fbResolvedTypeModel
                ResolveC2fbTypeModel(translation, catalog, _
                    baseTokens(), 0, baseTokenCount - 1, resolvedArrayFieldType, _
                    C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER)
                If resolvedArrayFieldType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0
                recordField.fieldType = GenericRecordValueFieldType( _
                    resolvedArrayFieldType)
            End If
        ElseIf Len(bindingOrder) > 0 AndAlso Left(bindingOrder, 1) = "P" Then
            Dim hasArrayOrFunction As Long = 0
            Dim pointerLevels As Long = 0
            For bindingIndex As Long = 1 To Len(bindingOrder)
                Select Case Mid(bindingOrder, bindingIndex, 1)
                Case "P": pointerLevels += 1
                Case "A", "F": hasArrayOrFunction = -1
                End Select
            Next
            If hasArrayOrFunction <> 0 Then
                recordField.fieldType = "Any Ptr"
            Else
                Dim pointerTokens() As String
                ReDim pointerTokens(0 To 31)
                Dim pointerTokenCount As Long = 0
                For tokenIndex As Long = 0 To baseTokenCount - 1
                    AddToken(pointerTokens(), pointerTokenCount, baseTokens(tokenIndex))
                Next
                For pointerIndex As Long = 1 To pointerLevels
                    AddToken(pointerTokens(), pointerTokenCount, "*")
                Next
                Dim resolvedPointerFieldType As C2fbResolvedTypeModel
                ResolveC2fbTypeModel(translation, catalog, _
                    pointerTokens(), 0, pointerTokenCount - 1, resolvedPointerFieldType, _
                    C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER)
                If resolvedPointerFieldType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0
                recordField.fieldType = resolvedPointerFieldType.freeBasicType
            End If
        ElseIf bindingOrder = "" Then
            Dim resolvedValueFieldType As C2fbResolvedTypeModel
            ResolveC2fbTypeModel(translation, catalog, _
                baseTokens(), 0, baseTokenCount - 1, resolvedValueFieldType, _
                C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER)
            If resolvedValueFieldType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0
            recordField.fieldType = GenericRecordValueFieldType( _
                resolvedValueFieldType)
        Else
            Return 0
        End If
    End If

    Dim stringOverrideMode As Long = GenericStringOverrideModeForFieldInPolicy( _
        translation.genericC.policy, ownerTag, ownerAlias, fieldName)
    If stringOverrideMode = 0 AndAlso arrayTypeAliasIndex >= 0 Then _
        stringOverrideMode = GenericStringOverrideModeInPolicy( _
            translation.genericC.policy, _
            translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).sourceName)
    If stringOverrideMode = 0 Then _
        stringOverrideMode = GenericHeaderFbfrogStringDefaultMode( _
            translation, commonType, recordField.fieldType)
    If stringOverrideMode > 0 AndAlso recordField.arrayCount = 0 AndAlso _
       recordField.isZeroLengthArray = 0 Then
        Dim characterScalarType As String = _
            GenericHeaderFbfrogCharacterScalarType( _
                translation, commonType, recordField.fieldType)
        If characterScalarType <> "" Then recordField.fieldType = characterScalarType
    End If
    If recordField.arrayCount > 0 AndAlso stringOverrideMode > 0 Then
        Dim fixedStringType As String
        Dim outerBounds As String
        Dim outerElementCount As Long
        If GenericHeaderFbfrogStringArrayShape( _
            translation.genericC.header, recordField.fieldType, _
            recordField.arrayBounds, recordField.arrayCount, fixedStringType, _
            outerBounds, outerElementCount) <> 0 Then
            recordField.fieldType = fixedStringType
            recordField.arrayCount = outerElementCount
            recordField.arrayBounds = outerBounds
            If recordField.arrayBounds = "" Then recordField.arrayCount = 0
            recordField.isZeroLengthArray = 0
        End If
    End If
    recordField.fieldType = ApplyGenericStringOverrideModeInHeader( _
        translation.genericC.header, stringOverrideMode, recordField.fieldType)
    If recordField.fieldType = "" OrElse recordField.fieldType = "void" Then Return 0
    If GenericHeaderTypeIsOpaqueEmptyRecordInHeader( _
        translation.genericC.header, recordField.fieldType) <> 0 Then Return 0
    ' crt/longdouble.bi carries the target C long-double size and alignment.
    ' Keep it as a direct member so body translation can resolve the C field.
    If bitfieldColonIndex >= 0 Then
        If bindingOrder <> "" OrElse recordField.arrayCount <> 0 Then Return 0
        Dim storageWidth As Long = GenericRecordBitFieldStorageWidthInBits( _
            translation, recordField.fieldType)
        If storageWidth = 0 OrElse bitfieldWidth > storageWidth Then Return 0
        recordField.isBitField = -1
        recordField.bitWidth = bitfieldWidth
        recordField.bitStorageWidth = storageWidth
    End If
    recordField.name = fieldName
    recordField.sourceName = fieldName
    If hasAnonymousEnumType <> 0 Then
        commonType = savedCommonType
        commonTypeTokenCount = savedCommonTypeTokenCount
    End If
    Return -1
End Function

Private Sub AppendGenericRecordField( _
    fields() As GenericRecordField, ByRef fieldCount As Long, _
    ByRef recordField As GenericRecordField _
)
    If fieldCount >= MAX_FUNCTIONS Then _
        ReportError("record exceeds the configured flattened field limit")
    If fieldCount > UBound(fields) Then _
        ReDim Preserve fields(0 To UBound(fields) * 2 + 1)
    fields(fieldCount) = recordField
    fieldCount += 1
End Sub

Private Sub AppendGenericRecordAggregateMarker( _
    fields() As GenericRecordField, ByRef fieldCount As Long, _
    ByVal itemKind As C2fbRecordBindingItemKind, ByVal isUnion As Long, _
    ByVal packValue As Long = 0 _
)
    Dim marker As GenericRecordField
    marker.itemKind = itemKind
    marker.isUnion = isUnion
    marker.packValue = packValue
    AppendGenericRecordField(fields(), fieldCount, marker)
End Sub

Private Sub MakeGenericRecordFieldNameUnique( _
    fields() As GenericRecordField, ByVal fieldCount As Long, _
    ByRef recordField As GenericRecordField, _
    ByRef fieldNameIndex As C2fbStringIndexMapModel _
)
    If C2fbFreeBasicFieldIdentifierNeedsEscape(recordField.name) <> 0 Then _
        recordField.name &= "_"
    ' Large SDK records can have thousands of members; avoid rescanning all
    ' prior fields for every case-insensitive name collision check.
    Do
        Dim canonicalName As String = LCase(recordField.name)
        If C2fbStringIndexMapLookup(fieldNameIndex, canonicalName) < 0 Then _
            Exit Do
        recordField.name &= "_"
    Loop
    If AddC2fbStringIndexMapEntry( _
        fieldNameIndex, LCase(recordField.name), fieldCount) = 0 Then _
        ReportError("record field-name index exceeds its configured limit")
End Sub

Private Function ParseGenericInlineRecordField( _
    ByVal sourceText As String, ByRef isUnion As Long, _
    ByRef bodyText As String, ByRef fieldDeclarators As String, _
    ByRef packValue As Long _
) As Long
    sourceText = Trim(sourceText)
    bodyText = ""
    fieldDeclarators = ""
    isUnion = 0
    packValue = 0
    If Left(LCase(sourceText), Len("__extension__")) = "__extension__" Then _
        sourceText = Trim(Mid(sourceText, Len("__extension__") + 1))

    Dim keywordLength As Long
    Dim lowered As String = LCase(sourceText)
    If Left(lowered, Len("struct")) = "struct" Then
        keywordLength = Len("struct")
    ElseIf Left(lowered, Len("union")) = "union" Then
        keywordLength = Len("union")
        isUnion = -1
    Else
        Return 0
    End If

    Dim openingBrace As Long = keywordLength + 1
    While openingBrace <= Len(sourceText) AndAlso _
          IsSpaceByte(Asc(sourceText, openingBrace)) <> 0
        openingBrace += 1
    Wend
    If openingBrace > Len(sourceText) OrElse _
       Asc(sourceText, openingBrace) <> Asc("{") Then Return 0

    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    Dim closingBrace As Long = 0
    For position As Long = openingBrace To Len(sourceText)
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
        If currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
        ElseIf currentByte = Asc("{") Then
            braceDepth += 1
        ElseIf currentByte = Asc("}") Then
            braceDepth -= 1
            If braceDepth < 0 Then Return 0
            If braceDepth = 0 Then
                closingBrace = position
                Exit For
            End If
        End If
    Next
    If quoteByte <> 0 OrElse braceDepth <> 0 OrElse closingBrace = 0 Then Return 0
    Dim trailingText As String = Trim(Mid(sourceText, closingBrace + 1))
    If InStr(LCase(trailingText), "__attribute__") <> 0 Then
        Dim loweredTrailing As String = LCase(trailingText)
        If InStr(loweredTrailing, "packed") = 0 OrElse _
           InStr(loweredTrailing, "aligned") <> 0 Then Return 0
        packValue = 1
        trailingText = Trim(StripCFunctionAttributes(trailingText))
    End If
    If trailingText = ";" Then
        trailingText = ""
    ElseIf trailingText <> "" Then
        Dim declaratorParts() As String
        Dim declaratorCount As Long
        If SplitSimpleCList( _
            trailingText, declaratorParts(), declaratorCount) = 0 OrElse _
           declaratorCount = 0 Then Return 0
        For declaratorIndex As Long = 0 To declaratorCount - 1
            Dim normalizedDeclarator As String = _
                StripCFunctionAttributes(declaratorParts(declaratorIndex))
            Dim declaratorTokens() As String
            Dim declaratorTokenCount As Long
            TokenizeCDeclaration( _
                normalizedDeclarator, declaratorTokens(), declaratorTokenCount)
            If declaratorTokenCount = 0 OrElse _
               declaratorTokenCount >= MAX_TYPE_WORDS Then Return 0
            Dim declaratorPosition As Long = 0
            While declaratorPosition < declaratorTokenCount
                Select Case declaratorTokens(declaratorPosition)
                Case "const", "volatile", "restrict", "__restrict", "__restrict__"
                    declaratorPosition += 1
                Case Else
                    Exit While
                End Select
            Wend
            If declaratorPosition >= declaratorTokenCount Then Return 0
            Dim declaratorModel As C2fbDeclaratorModel
            If ParseCDeclaratorModel( _
                declaratorTokens(), declaratorPosition, _
                declaratorTokenCount - 1, declaratorModel) = 0 OrElse _
               declaratorPosition <> declaratorTokenCount OrElse _
               IsIdentifierToken(declaratorModel.name) = 0 Then Return 0
        Next
        fieldDeclarators = trailingText
    End If
    bodyText = Mid(sourceText, openingBrace + 1, closingBrace - openingBrace - 1)
    Return -1
End Function

Private Sub AppendGenericRecordFieldText( _
    fieldTexts() As String, ByRef fieldCount As Long, _
    ByVal fieldText As String _
)
    fieldText = Trim(fieldText)
    If fieldText = "" Then Exit Sub
    If fieldCount >= MAX_FUNCTIONS Then _
        ReportError("record exceeds the configured nested declaration limit")
    If fieldCount > UBound(fieldTexts) Then _
        ReDim Preserve fieldTexts(0 To UBound(fieldTexts) * 2 + 1)
    fieldTexts(fieldCount) = fieldText
    fieldCount += 1
End Sub

Private Function SplitGenericRecordFieldStatements( _
    ByVal bodyText As String, fieldTexts() As String, _
    ByRef fieldCount As Long _
) As Long
    ReDim fieldTexts(0 To 15)
    fieldCount = 0
    Dim fieldStart As Long = 1
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    For position As Long = 1 To Len(bodyText)
        Dim currentByte As Long = Asc(bodyText, position)
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
            parenDepth += 1
        ElseIf currentByte = Asc(")") Then
            parenDepth -= 1
        ElseIf currentByte = Asc("[") Then
            bracketDepth += 1
        ElseIf currentByte = Asc("]") Then
            bracketDepth -= 1
        ElseIf currentByte = Asc("{") Then
            braceDepth += 1
        ElseIf currentByte = Asc("}") Then
            braceDepth -= 1
        ElseIf currentByte = Asc(";") AndAlso parenDepth = 0 AndAlso _
               bracketDepth = 0 AndAlso braceDepth = 0 Then
            AppendGenericRecordFieldText( _
                fieldTexts(), fieldCount, _
                Mid(bodyText, fieldStart, position - fieldStart))
            fieldStart = position + 1
        End If
        If parenDepth < 0 OrElse bracketDepth < 0 OrElse braceDepth < 0 Then Return 0
    Next
    If quoteByte <> 0 OrElse parenDepth <> 0 OrElse _
       bracketDepth <> 0 OrElse braceDepth <> 0 OrElse _
       Trim(Mid(bodyText, fieldStart)) <> "" OrElse fieldCount = 0 Then Return 0
    Return -1
End Function

Private Function AllocateGenericZeroArrayAccessorName( _
    ByRef translation As C2fbTranslationContext, _
    ByVal ownerTag As String, ByVal ownerAlias As String, _
    ByVal fieldName As String, outputNames() As String, _
    ByRef outputNameCount As Long _
) As String
    Dim ownerName As String = ownerTag
    If ownerName = "" Then ownerName = ownerAlias
    If ownerName = "" Then ownerName = "record"
    Dim accessorName As String = translation.genericC.policy.generatedNamePrefix & _
        ownerName & "_" & fieldName & "_tail_ptr"
    While 1
        Dim nameConflict As Long = 0
        For outputIndex As Long = 0 To outputNameCount - 1
            If LCase(outputNames(outputIndex)) = LCase(accessorName) Then
                nameConflict = -1
                Exit For
            End If
        Next
        If nameConflict = 0 Then
            For planIndex As Long = 0 To _
                translation.sourceUnit.declarationCount - 1
                If translation.genericC.header.recordPlans(planIndex).isPrepared <> 0 AndAlso _
                   LCase(translation.genericC.header.recordPlans(planIndex).implementationName) = _
                   LCase(accessorName) Then
                    nameConflict = -1
                    Exit For
                End If
            Next
        End If
        If nameConflict = 0 Then Exit While
        accessorName &= "_"
    Wend
    If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
        ReportError("generic header exceeds the zero-length array accessor limit")
    If outputNameCount > UBound(outputNames) Then _
        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
    outputNames(outputNameCount) = accessorName
    outputNameCount += 1
    Return accessorName
End Function

Private Function GenericFlexibleArrayElementTypeSupported( _
    ByRef translation As C2fbTranslationContext, _
    ByVal fieldType As String _
) As Long
    fieldType = Trim(fieldType)
    If Left(LCase(fieldType), Len("const ")) = "const " Then _
        fieldType = Trim(Mid(fieldType, Len("const ") + 1))
    If fieldType = "" OrElse fieldType = "Any" OrElse _
       InStr(fieldType, "CLongDouble") <> 0 Then Return 0
    If InStr(LCase(fieldType), " ptr") <> 0 Then Return -1

    Dim storageType As String = _
        GenericHeaderTypeAliasStorageTypeInHeader( _
            translation.genericC.header, fieldType, 0)
    If storageType = "" OrElse storageType = "Any" OrElse _
       InStr(storageType, "CLongDouble") <> 0 Then Return 0
    If storageType <> "Record" Then Return -1

    For dependencyIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(dependencyIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) Then Continue For
            Dim plan As C2fbGenericRecordPlanModel = _
                translation.genericC.header.recordPlans(dependencyIndex)
            If plan.isPrepared = 0 OrElse plan.isSupported = 0 OrElse _
               plan.isExcluded <> 0 OrElse plan.isOpaqueEmpty <> 0 OrElse _
               plan.bindingReady = 0 Then Continue For
            If LCase(fieldType) = LCase(plan.freeBasicName) OrElse _
               LCase(fieldType) = LCase(plan.aliasFreeBasicName) OrElse _
               LCase(fieldType) = LCase(.recordTag) OrElse _
               LCase(fieldType) = LCase(.recordAlias) Then Return -1
        End With
    Next
    Return 0
End Function

Private Function AppendGenericZeroLengthArrayNote( _
    ByRef translation As C2fbTranslationContext, _
    ByVal ownerTag As String, ByVal ownerAlias As String, _
    outputNames() As String, ByRef outputNameCount As Long, _
    fields() As GenericRecordField, ByRef fieldCount As Long, _
    ByRef fieldNameIndex As C2fbStringIndexMapModel, _
    ByRef zeroArrayField As GenericRecordField _
) As Long
    If zeroArrayField.isZeroLengthArray = 0 Then Return 0
    Dim isByteFlexibleArray As Long = CInt( _
        LCase(zeroArrayField.fieldType) = "byte" OrElse _
        LCase(zeroArrayField.fieldType) = "ubyte")
    If isByteFlexibleArray = 0 Then
        If GenericFlexibleArrayElementTypeSupported( _
            translation, zeroArrayField.fieldType) = 0 Then Return 0
        Dim storageField As GenericRecordField
        storageField.name = "_c2fb_" & zeroArrayField.name & "_flex_storage"
        storageField.itemKind = C2FB_RECORD_BINDING_ITEM_FIELD
        MakeGenericRecordFieldNameUnique( _
            fields(), fieldCount, storageField, fieldNameIndex)
        zeroArrayField.zeroArrayStorageName = storageField.name
    End If
    If fieldCount > 0 Then
        Dim precedingField As GenericRecordField = fields(fieldCount - 1)
        If precedingField.itemKind <> C2FB_RECORD_BINDING_ITEM_FIELD OrElse _
           precedingField.isBitField <> 0 Then Return 0
        zeroArrayField.zeroArrayPreviousFieldName = precedingField.name
        zeroArrayField.zeroArrayPreviousArrayCount = precedingField.arrayCount
    End If
    zeroArrayField.itemKind = C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY
    zeroArrayField.zeroArrayAccessorName = _
        AllocateGenericZeroArrayAccessorName( _
            translation, ownerTag, ownerAlias, zeroArrayField.name, _
            outputNames(), outputNameCount)
    MakeGenericRecordFieldNameUnique( _
        fields(), fieldCount, zeroArrayField, fieldNameIndex)
    AppendGenericRecordField(fields(), fieldCount, zeroArrayField)
    Return -1
End Function

Private Function AppendGenericRecordSimpleFields( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceText As String, _
    ByVal ownerTag As String, ByVal ownerAlias As String, _
    ByVal isLastStatement As Long, ByVal parentIsUnion As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    fields() As GenericRecordField, ByRef fieldCount As Long, _
    ByRef fieldNameIndex As C2fbStringIndexMapModel _
) As Long
    Dim parts() As String
    Dim partCount As Long
    If SplitSimpleCList(sourceText, parts(), partCount) = 0 OrElse _
       partCount = 0 Then Return 0
    Dim commonType As String
    For partIndex As Long = 0 To partCount - 1
        Dim recordField As GenericRecordField
        If TranslateGenericRecordField( _
            translation, catalog, parts(partIndex), commonType, _
            CInt(partIndex = 0), ownerTag, ownerAlias, recordField) = 0 Then _
            Return 0
        If recordField.isZeroLengthArray <> 0 Then
            If isLastStatement = 0 OrElse partIndex <> partCount - 1 OrElse _
               parentIsUnion <> 0 OrElse AppendGenericZeroLengthArrayNote( _
                translation, ownerTag, ownerAlias, outputNames(), _
                outputNameCount, fields(), fieldCount, fieldNameIndex, _
                recordField) = 0 Then _
                Return 0
        Else
            recordField.itemKind = C2FB_RECORD_BINDING_ITEM_FIELD
            MakeGenericRecordFieldNameUnique( _
                fields(), fieldCount, recordField, fieldNameIndex)
            AppendGenericRecordField(fields(), fieldCount, recordField)
        End If
    Next
    Return -1
End Function

Declare Function AppendGenericNamedAggregateField( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal bodyText As String, _
    ByVal isUnion As Long, ByVal fieldDeclarators As String, _
    ByVal ownerTag As String, ByVal ownerAlias As String, _
    ByVal nestingDepth As Long, _
    ByRef recordPlan As C2fbGenericRecordPlanModel, _
    outputNames() As String, ByRef outputNameCount As Long, _
    fields() As GenericRecordField, ByRef fieldCount As Long, _
    ByRef fieldNameIndex As C2fbStringIndexMapModel _
) As Long

Private Function ParseGenericRecordNestedFields( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal bodyText As String, _
    ByVal ownerTag As String, ByVal ownerAlias As String, _
    ByVal parentIsUnion As Long, ByVal nestingDepth As Long, _
    ByRef recordPlan As C2fbGenericRecordPlanModel, _
    outputNames() As String, ByRef outputNameCount As Long, _
    fields() As GenericRecordField, ByRef fieldCount As Long, _
    ByRef fieldNameIndex As C2fbStringIndexMapModel _
) As Long
    Dim fieldTexts() As String
    Dim nestedFieldCount As Long
    If nestingDepth > MAX_GENERIC_RECORD_NESTING OrElse _
       SplitGenericRecordFieldStatements( _
        bodyText, fieldTexts(), nestedFieldCount) = 0 Then Return 0

    For nestedFieldIndex As Long = 0 To nestedFieldCount - 1
        Dim childIsUnion As Long
        Dim childBody As String
        Dim childFieldDeclarators As String
        Dim childPackValue As Long
        If ParseGenericInlineRecordField( _
            fieldTexts(nestedFieldIndex), childIsUnion, childBody, _
            childFieldDeclarators, childPackValue) <> 0 Then
            If childFieldDeclarators <> "" Then
                If AppendGenericNamedAggregateField( _
                    translation, catalog, childBody, childIsUnion, _
                    childFieldDeclarators, _
                    ownerTag, ownerAlias, nestingDepth + 1, recordPlan, _
                    outputNames(), outputNameCount, fields(), fieldCount, _
                    fieldNameIndex) = 0 Then _
                    Return 0
                Continue For
            End If
            If Trim(childBody) = "" Then Continue For
            If nestingDepth >= MAX_GENERIC_RECORD_NESTING Then Return 0
            ' FreeBASIC requires anonymous Type/Union blocks to alternate.
            ' A single-member opposite-kind wrapper preserves this C aggregate's
            ' size and alignment while exposing its fields at the same level.
            Dim wrapperIsUnion As Long = 0
            If childIsUnion = parentIsUnion Then
                wrapperIsUnion = CInt(childIsUnion = 0) * -1
                AppendGenericRecordAggregateMarker( _
                    fields(), fieldCount, _
                    C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN, wrapperIsUnion, _
                    childPackValue)
            End If
            AppendGenericRecordAggregateMarker( _
                fields(), fieldCount, _
                C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN, childIsUnion, _
                childPackValue)
            If ParseGenericRecordNestedFields( _
                translation, catalog, childBody, ownerTag, ownerAlias, _
                childIsUnion, nestingDepth + 1, recordPlan, _
                outputNames(), outputNameCount, fields(), fieldCount, _
                fieldNameIndex) = 0 Then _
                Return 0
            AppendGenericRecordAggregateMarker( _
                fields(), fieldCount, _
                C2FB_RECORD_BINDING_ITEM_ANONYMOUS_END, childIsUnion)
            If childIsUnion = parentIsUnion Then
                AppendGenericRecordAggregateMarker( _
                    fields(), fieldCount, _
                    C2FB_RECORD_BINDING_ITEM_ANONYMOUS_END, wrapperIsUnion)
            End If
        ElseIf AppendGenericRecordSimpleFields( _
            translation, catalog, fieldTexts(nestedFieldIndex), _
            ownerTag, ownerAlias, _
            CInt(nestedFieldIndex = nestedFieldCount - 1), parentIsUnion, _
            outputNames(), outputNameCount, fields(), fieldCount, _
            fieldNameIndex) = 0 Then
            Return 0
        End If
    Next
    Return -1
End Function

Private Function GenericRecordBitFieldRunFillsStorage( _
    ByVal runWidth As Long, ByVal storageWidth As Long _
) As Long
    If runWidth <= 0 OrElse storageWidth <= 0 Then Return 0
    Dim usedBytes As Long = (runWidth + 7) \ 8
    Dim storageBytes As Long = (storageWidth + 7) \ 8
    Return CInt(usedBytes >= storageBytes) * -1
End Function

Private Function GenericRecordBitFieldNeedsFullStorage( _
    ByVal packingCap As Long, ByVal storageWidth As Long _
) As Long
    If packingCap <= 0 OrElse storageWidth <= 0 Then Return 0
    Dim storageBytes As Long = (storageWidth + 7) \ 8
    Return CInt(packingCap < storageBytes) * -1
End Function

Private Function GenericRecordNestedTypeAlignmentBytes( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicType As String _
) As Long
    Dim helperPrefix As String = _
        LCase(translation.genericC.policy.generatedNamePrefix)
    If helperPrefix = "" Then
        helperPrefix = "_c2fb_inline_"
    Else
        helperPrefix &= "_c2fb_inline_"
    End If
    If Left(LCase(freeBasicType), Len(helperPrefix)) <> helperPrefix Then _
        Return 0
    For planIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.genericC.header.recordPlans(planIndex)
            For nestedIndex As Long = 0 To .nestedBindingCount - 1
                Dim nestedBinding As C2fbRecordBindingModel = _
                    .nestedBindings(nestedIndex)
                If LCase(nestedBinding.freeBasicName) <> _
                   LCase(freeBasicType) Then Continue For
                If nestedBinding.naturalAlignmentValue > 0 Then _
                    Return nestedBinding.naturalAlignmentValue
                If nestedBinding.alignmentValue > 0 Then _
                    Return nestedBinding.alignmentValue
                Return 0
            Next
        End With
    Next
    Return 0
End Function

Private Function GenericRecordFieldAlignmentBytes( _
    ByRef translation As C2fbTranslationContext, ByVal fieldType As String _
) As Long
    fieldType = Trim(fieldType)
    If Left(LCase(fieldType), Len("const ")) = "const " Then _
        fieldType = Trim(Mid(fieldType, Len("const ") + 1))

    Dim pointerCount As Long = 0
    While Right(LCase(fieldType), Len(" ptr")) = " ptr"
        fieldType = Trim(Left(fieldType, Len(fieldType) - Len(" ptr")))
        pointerCount += 1
    Wend
    If pointerCount > 0 Then
        Dim pointerWidth As Long = GenericPreprocessorTypeWidthInBits( _
            translation, "__SIZEOF_POINTER__", 4)
        If pointerWidth <= 0 OrElse pointerWidth Mod 8 <> 0 Then Return 0
        Return pointerWidth \ 8
    End If

    Dim aliasStorageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, fieldType, 0)
    If InStr(LCase(fieldType), "clongdouble") <> 0 OrElse _
       LCase(aliasStorageType) = "clongdouble" Then _
        Return GenericHeaderCLongDoubleAlignmentBytes(translation)

    Dim naturalTypeAliasIndex As Long = _
        GenericHeaderTypeAliasIndexByFreeBasicNameInHeader( _
            translation.genericC.header, fieldType)
    If naturalTypeAliasIndex >= 0 Then
        With translation.genericC.header.headerTypeAliases(naturalTypeAliasIndex)
            If .naturalAlignmentValue > .alignmentValue Then _
                Return .naturalAlignmentValue
            If .alignmentValue > 0 Then Return .alignmentValue
        End With
    End If

    Dim nestedAlignment As Long = GenericRecordNestedTypeAlignmentBytes( _
        translation, fieldType)
    If nestedAlignment > 0 Then Return nestedAlignment

    Dim mappedTypeAlignment As Long = _
        GenericTypeOverrideAlignmentByFreeBasicTypeInPolicy( _
            translation.genericC.policy, fieldType)
    If mappedTypeAlignment > 0 Then Return mappedTypeAlignment

    If aliasStorageType <> "" AndAlso _
       LCase(aliasStorageType) <> "record" AndAlso _
       LCase(aliasStorageType) <> "union" Then _
        fieldType = aliasStorageType

    Select Case LCase(fieldType)
    Case "byte", "ubyte", "boolean", "c2fb_c_char", "c2fb_c_uchar"
        Return 1
    Case "short", "ushort", "c2fb_c_short", "c2fb_c_ushort"
        Return 2
    Case "long", "ulong", "single", "c2fb_c_int", "c2fb_c_uint"
        Return 4
    Case "integer", "uinteger"
        Dim pointerWidth As Long = GenericPreprocessorTypeWidthInBits( _
            translation, "__SIZEOF_POINTER__", 4)
        If pointerWidth <= 0 OrElse pointerWidth Mod 8 <> 0 Then Return 0
        Return pointerWidth \ 8
    Case "clong", "culong", "c2fb_c_long", "c2fb_c_ulong"
        Dim longWidth As Long = GenericPreprocessorTypeWidthInBits( _
            translation, "__SIZEOF_LONG__", 4)
        If longWidth <= 0 OrElse longWidth Mod 8 <> 0 Then Return 0
        Return longWidth \ 8
    Case "longint", "ulongint", "double", "c2fb_int64", "c2fb_uint64"
        Dim pointerWidth As Long = GenericPreprocessorTypeWidthInBits( _
            translation, "__SIZEOF_POINTER__", 4)
        If pointerWidth <= 32 OrElse pointerWidth Mod 8 <> 0 Then Return 0
        Return 8
    Case "clongdouble"
        Return GenericHeaderCLongDoubleAlignmentBytes(translation)
    End Select

    If Left(LCase(fieldType), Len("_c2fb_record_")) = _
       "_c2fb_record_" Then
        Dim pointerWidth As Long = GenericPreprocessorTypeWidthInBits( _
            translation, "__SIZEOF_POINTER__", 4)
        If pointerWidth > 0 AndAlso pointerWidth Mod 8 = 0 Then _
            Return pointerWidth \ 8
    End If
    Return 0
End Function

Private Function GenericRecordBindingNaturalAlignmentBytes( _
    ByRef translation As C2fbTranslationContext, _
    ByRef recordBinding As C2fbRecordBindingModel _
) As Long
    Dim maximumAlignment As Long = 1
    For itemIndex As Long = 0 To recordBinding.itemCount - 1
        With recordBinding.items(itemIndex)
            If .kind <> C2FB_RECORD_BINDING_ITEM_FIELD Then Continue For
            Dim fieldAlignment As Long = _
                GenericRecordFieldAlignmentBytes(translation, .fieldType)
            If fieldAlignment <= 0 Then Return 0

            Dim packingCap As Long = .packValue
            If packingCap = 0 Then packingCap = recordBinding.packValue
            If packingCap = 0 AndAlso recordBinding.isPacked <> 0 Then _
                packingCap = 1
            If packingCap > 0 AndAlso fieldAlignment > packingCap Then _
                fieldAlignment = packingCap
            If fieldAlignment > maximumAlignment Then _
                maximumAlignment = fieldAlignment
        End With
    Next
    Return maximumAlignment
End Function

Private Function GenericRecordBindingHasNestedAggregate( _
    ByRef translation As C2fbTranslationContext, _
    ByRef recordBinding As C2fbRecordBindingModel _
) As Long
    For itemIndex As Long = 0 To recordBinding.itemCount - 1
        With recordBinding.items(itemIndex)
            If .kind = C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN OrElse _
               .alignmentStorageType <> "" Then Return -1
            If .kind <> C2FB_RECORD_BINDING_ITEM_FIELD Then Continue For

            Dim fieldType As String = Trim(.fieldType)
            If Left(LCase(fieldType), Len("const ")) = "const " Then _
                fieldType = Trim(Mid(fieldType, Len("const ") + 1))
            Dim pointerDepth As Long = 0
            While Right(LCase(fieldType), Len(" ptr")) = " ptr"
                fieldType = Trim(Left(fieldType, Len(fieldType) - Len(" ptr")))
                pointerDepth += 1
            Wend
            If pointerDepth > 0 Then Continue For

            Dim aliasStorageType As String = _
                GenericHeaderTypeAliasStorageTypeInHeader( _
                    translation.genericC.header, fieldType, 0)
            If InStr(LCase(fieldType), "clongdouble") <> 0 OrElse _
               LCase(aliasStorageType) = "clongdouble" Then Return -1
            If LCase(aliasStorageType) = "record" OrElse _
               LCase(aliasStorageType) = "union" OrElse _
               Left(LCase(fieldType), Len("_c2fb_record_")) = _
                   "_c2fb_record_" Then Return -1
        End With
    Next
    Return 0
End Function

Private Function GenericRecordBitFieldRunCanPrecedeField( _
    ByRef translation As C2fbTranslationContext, _
    ByVal runWidth As Long, ByVal storageWidth As Long, _
    ByVal packingCap As Long, ByVal nextFieldType As String _
) As Long
    If GenericRecordBitFieldRunFillsStorage( _
        runWidth, storageWidth) <> 0 Then Return -1
    If GenericRecordBitFieldNeedsFullStorage( _
        packingCap, storageWidth) <> 0 Then Return 0

    Dim storageBytes As Long = (storageWidth + 7) \ 8
    Dim nextFieldAlignment As Long = _
        GenericRecordFieldAlignmentBytes(translation, nextFieldType)
    If storageBytes <= 0 OrElse nextFieldAlignment < storageBytes Then Return 0

    ' A sufficiently aligned following field cannot reuse the unused tail of
    ' this allocation unit, so both C and FreeBASIC start it after the unit.
    Return -1
End Function

Private Function ValidateGenericRecordFieldItems( _
    ByRef translation As C2fbTranslationContext, _
    fields() As GenericRecordField, ByVal fieldCount As Long, _
    ByVal rootIsUnion As Long, ByVal rootPackingCap As Long _
) As Long
    Dim aggregateKinds(0 To MAX_GENERIC_RECORD_OUTPUT_NESTING) As Long
    Dim aggregatePackingCaps(0 To MAX_GENERIC_RECORD_OUTPUT_NESTING) As Long
    Dim bitfieldRunWidths(0 To MAX_GENERIC_RECORD_OUTPUT_NESTING) As Long
    Dim bitfieldStorageWidths(0 To MAX_GENERIC_RECORD_OUTPUT_NESTING) As Long
    Dim bitfieldRunActive(0 To MAX_GENERIC_RECORD_OUTPUT_NESTING) As Long
    Dim nestingDepth As Long = 0
    Dim simpleFieldCount As Long = 0
    aggregateKinds(0) = rootIsUnion
    aggregatePackingCaps(0) = rootPackingCap
    For itemIndex As Long = 0 To fieldCount - 1
        Select Case fields(itemIndex).itemKind
        Case C2FB_RECORD_BINDING_ITEM_FIELD
            If fields(itemIndex).name = "" OrElse _
               fields(itemIndex).fieldType = "" OrElse _
               fields(itemIndex).fieldType = "void" OrElse _
               fields(itemIndex).arrayCount < 0 Then Return 0
            If fields(itemIndex).isBitField <> 0 AndAlso _
               (fields(itemIndex).bitWidth <= 0 OrElse _
                fields(itemIndex).arrayCount <> 0 OrElse _
                fields(itemIndex).bitStorageWidth <= 0 OrElse _
                fields(itemIndex).bitWidth > fields(itemIndex).bitStorageWidth) Then _
                Return 0
            If fields(itemIndex).isBitField <> 0 Then
                If aggregateKinds(nestingDepth) <> 0 Then
                    If GenericRecordBitFieldNeedsFullStorage( _
                        aggregatePackingCaps(nestingDepth), _
                        fields(itemIndex).bitStorageWidth) <> 0 AndAlso _
                       GenericRecordBitFieldRunFillsStorage( _
                        fields(itemIndex).bitWidth, _
                        fields(itemIndex).bitStorageWidth) = 0 Then Return 0
                ElseIf bitfieldRunActive(nestingDepth) = 0 Then
                    bitfieldRunActive(nestingDepth) = -1
                    bitfieldRunWidths(nestingDepth) = fields(itemIndex).bitWidth
                    bitfieldStorageWidths(nestingDepth) = _
                        fields(itemIndex).bitStorageWidth
                ElseIf bitfieldStorageWidths(nestingDepth) <> _
                       fields(itemIndex).bitStorageWidth Then
                    If GenericRecordBitFieldRunFillsStorage( _
                        bitfieldRunWidths(nestingDepth), _
                        bitfieldStorageWidths(nestingDepth)) = 0 Then Return 0
                    bitfieldRunWidths(nestingDepth) = fields(itemIndex).bitWidth
                    bitfieldStorageWidths(nestingDepth) = _
                        fields(itemIndex).bitStorageWidth
                ElseIf bitfieldRunWidths(nestingDepth) + _
                       fields(itemIndex).bitWidth <= _
                           bitfieldStorageWidths(nestingDepth) Then
                    bitfieldRunWidths(nestingDepth) += fields(itemIndex).bitWidth
                Else
                    ' A bitfield that no longer fits starts a fresh allocation
                    ' unit in both layouts; the prior unit is fully occupied.
                    bitfieldRunWidths(nestingDepth) = fields(itemIndex).bitWidth
                    bitfieldStorageWidths(nestingDepth) = _
                        fields(itemIndex).bitStorageWidth
                End If
            ElseIf aggregateKinds(nestingDepth) = 0 AndAlso _
                   bitfieldRunActive(nestingDepth) <> 0 Then
                If GenericRecordBitFieldRunCanPrecedeField( _
                    translation, bitfieldRunWidths(nestingDepth), _
                    bitfieldStorageWidths(nestingDepth), _
                    aggregatePackingCaps(nestingDepth), fields(itemIndex).fieldType) = 0 Then _
                    Return 0
                bitfieldRunActive(nestingDepth) = 0
                bitfieldRunWidths(nestingDepth) = 0
                bitfieldStorageWidths(nestingDepth) = 0
            End If
            simpleFieldCount += 1
        Case C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY
            If fields(itemIndex).name = "" OrElse _
               fields(itemIndex).fieldType = "" OrElse _
               fields(itemIndex).zeroArrayAccessorName = "" OrElse _
               fields(itemIndex).arrayCount <> 0 Then Return 0
        Case C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN
            If nestingDepth >= MAX_GENERIC_RECORD_OUTPUT_NESTING Then Return 0
            If aggregateKinds(nestingDepth) = 0 AndAlso _
               bitfieldRunActive(nestingDepth) <> 0 Then
                If GenericRecordBitFieldRunFillsStorage( _
                    bitfieldRunWidths(nestingDepth), _
                    bitfieldStorageWidths(nestingDepth)) = 0 Then Return 0
                bitfieldRunActive(nestingDepth) = 0
            End If
            nestingDepth += 1
            aggregateKinds(nestingDepth) = fields(itemIndex).isUnion
            aggregatePackingCaps(nestingDepth) = aggregatePackingCaps(nestingDepth - 1)
            If fields(itemIndex).packValue > 0 AndAlso _
               (aggregatePackingCaps(nestingDepth) = 0 OrElse _
                fields(itemIndex).packValue < aggregatePackingCaps(nestingDepth)) Then _
                aggregatePackingCaps(nestingDepth) = fields(itemIndex).packValue
        Case C2FB_RECORD_BINDING_ITEM_ANONYMOUS_END
            If nestingDepth <= 0 Then Return 0
            If aggregateKinds(nestingDepth) = 0 AndAlso _
               bitfieldRunActive(nestingDepth) <> 0 AndAlso _
               GenericRecordBitFieldNeedsFullStorage( _
                   aggregatePackingCaps(nestingDepth), _
                   bitfieldStorageWidths(nestingDepth)) <> 0 AndAlso _
               GenericRecordBitFieldRunFillsStorage( _
                   bitfieldRunWidths(nestingDepth), _
                   bitfieldStorageWidths(nestingDepth)) = 0 Then Return 0
            If aggregateKinds(nestingDepth) <> fields(itemIndex).isUnion Then Return 0
            nestingDepth -= 1
        Case Else
            Return 0
        End Select
    Next
    If nestingDepth <> 0 OrElse simpleFieldCount = 0 Then Return 0
    If aggregateKinds(0) = 0 AndAlso bitfieldRunActive(0) <> 0 AndAlso _
       GenericRecordBitFieldNeedsFullStorage( _
           aggregatePackingCaps(0), bitfieldStorageWidths(0)) <> 0 AndAlso _
       GenericRecordBitFieldRunFillsStorage( _
           bitfieldRunWidths(0), bitfieldStorageWidths(0)) = 0 Then Return 0
    Return -1
End Function

Private Function GenericRecordOnlyPackedTopLevelAggregate( _
    fields() As GenericRecordField, ByVal fieldCount As Long _
) As Long
    Dim nestingDepth As Long = 0
    Dim topLevelAggregateCount As Long = 0
    Dim topLevelPackValue As Long = 0
    For itemIndex As Long = 0 To fieldCount - 1
        Select Case fields(itemIndex).itemKind
        Case C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN
            If nestingDepth = 0 Then
                topLevelAggregateCount += 1
                topLevelPackValue = fields(itemIndex).packValue
                If topLevelPackValue = 0 Then Return 0
            End If
            nestingDepth += 1
        Case C2FB_RECORD_BINDING_ITEM_ANONYMOUS_END
            If nestingDepth <= 0 Then Return 0
            nestingDepth -= 1
        Case Else
            If nestingDepth = 0 Then Return 0
        End Select
    Next
    If nestingDepth <> 0 OrElse topLevelAggregateCount <> 1 Then Return 0
    Return topLevelPackValue
End Function


Private Function AppendGenericNamedAggregateField( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal bodyText As String, _
    ByVal isUnion As Long, ByVal fieldDeclarators As String, _
    ByVal ownerTag As String, ByVal ownerAlias As String, _
    ByVal nestingDepth As Long, _
    ByRef recordPlan As C2fbGenericRecordPlanModel, _
    outputNames() As String, ByRef outputNameCount As Long, _
    fields() As GenericRecordField, ByRef fieldCount As Long, _
    ByRef fieldNameIndex As C2fbStringIndexMapModel _
) As Long
    If nestingDepth > MAX_GENERIC_RECORD_NESTING Then Return 0
    If recordPlan.nestedBindingSequence >= MAX_FUNCTIONS Then _
        ReportError("record exceeds the configured nested type limit")
    recordPlan.nestedBindingSequence += 1

    Dim helperSourceName As String = "_c2fb_inline_" & _
        Trim(Str(recordPlan.sourceDeclarationIndex)) & "_" & _
        Trim(Str(recordPlan.nestedBindingSequence))
    Dim helperName As String = _
        translation.genericC.policy.generatedNamePrefix & helperSourceName
    While 1
        Dim nameConflict As Long = 0
        For outputNameIndex As Long = 0 To outputNameCount - 1
            If LCase(outputNames(outputNameIndex)) = LCase(helperName) Then
                nameConflict = -1
                Exit For
            End If
        Next
        If nameConflict = 0 Then
            For planIndex As Long = 0 To _
                translation.sourceUnit.declarationCount - 1
                If LCase(translation.genericC.header.recordPlans(planIndex).implementationName) = _
                   LCase(helperName) Then
                    nameConflict = -1
                    Exit For
                End If
            Next
        End If
        If nameConflict = 0 AndAlso _
           (GenericHeaderTypeAliasIndexInHeader( _
                translation.genericC.header, helperName, 0) >= 0 OrElse _
            GenericHeaderTypeAliasIndexInHeader( _
                translation.genericC.header, helperName, -1) >= 0) Then _
            nameConflict = -1
        If nameConflict = 0 Then Exit While
        helperName &= "_"
    Wend
    If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
        ReportError("generic header exceeds the nested record type limit")
    If outputNameCount > UBound(outputNames) Then _
        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
    outputNames(outputNameCount) = helperName
    outputNameCount += 1

    Dim nestedFields() As GenericRecordField
    ReDim nestedFields(0 To 15)
    Dim nestedFieldCount As Long = 0
    Dim nestedFieldNameIndex As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(nestedFieldNameIndex)
    If ParseGenericRecordNestedFields( _
        translation, catalog, bodyText, ownerTag, ownerAlias, isUnion, _
        nestingDepth, recordPlan, outputNames(), outputNameCount, _
        nestedFields(), nestedFieldCount, nestedFieldNameIndex) = 0 OrElse _
       ValidateGenericRecordFieldItems( _
        translation, nestedFields(), nestedFieldCount, isUnion, 0) = 0 Then Return 0

    Dim nestedBinding As C2fbRecordBindingModel
    nestedBinding.freeBasicName = helperName
    nestedBinding.isUnion = isUnion
    nestedBinding.itemCount = nestedFieldCount
    If nestedFieldCount > 0 Then
        ReDim nestedBinding.items(0 To nestedFieldCount - 1)
        For itemIndex As Long = 0 To nestedFieldCount - 1
            nestedBinding.items(itemIndex).kind = nestedFields(itemIndex).itemKind
            nestedBinding.items(itemIndex).isUnion = nestedFields(itemIndex).isUnion
            nestedBinding.items(itemIndex).packValue = nestedFields(itemIndex).packValue
            nestedBinding.items(itemIndex).isBitField = nestedFields(itemIndex).isBitField
            nestedBinding.items(itemIndex).isArraySizeHinted = _
                nestedFields(itemIndex).isArraySizeHinted
            nestedBinding.items(itemIndex).bitWidth = nestedFields(itemIndex).bitWidth
            nestedBinding.items(itemIndex).name = nestedFields(itemIndex).name
            nestedBinding.items(itemIndex).sourceName = _
                nestedFields(itemIndex).sourceName
            nestedBinding.items(itemIndex).fieldType = nestedFields(itemIndex).fieldType
            nestedBinding.items(itemIndex).arrayCount = nestedFields(itemIndex).arrayCount
            nestedBinding.items(itemIndex).arrayBounds = _
                nestedFields(itemIndex).arrayBounds
            nestedBinding.items(itemIndex).zeroArrayAccessorName = _
                nestedFields(itemIndex).zeroArrayAccessorName
            nestedBinding.items(itemIndex).zeroArrayStorageName = _
                nestedFields(itemIndex).zeroArrayStorageName
            nestedBinding.items(itemIndex).zeroArrayPreviousFieldName = _
                nestedFields(itemIndex).zeroArrayPreviousFieldName
            nestedBinding.items(itemIndex).zeroArrayPreviousArrayCount = _
                nestedFields(itemIndex).zeroArrayPreviousArrayCount
        Next
    End If
    nestedBinding.naturalAlignmentValue = _
        GenericRecordBindingNaturalAlignmentBytes(translation, nestedBinding)
    If nestedBinding.naturalAlignmentValue <= 0 AndAlso _
       GenericRecordBindingHasNestedAggregate(translation, nestedBinding) <> 0 Then
        Dim pointerWidth As Long = GenericPreprocessorTypeWidthInBits( _
            translation, "__SIZEOF_POINTER__", 4)
        If pointerWidth > 0 AndAlso pointerWidth Mod 8 = 0 Then _
            nestedBinding.naturalAlignmentValue = pointerWidth \ 8
    End If
    If recordPlan.nestedBindingCount >= MAX_FUNCTIONS Then _
        ReportError("record contains too many nested aggregate types")
    If recordPlan.nestedBindingCount > UBound(recordPlan.nestedBindings) Then _
        ReDim Preserve recordPlan.nestedBindings( _
            0 To UBound(recordPlan.nestedBindings) * 2 + 1)
    recordPlan.nestedBindings(recordPlan.nestedBindingCount) = nestedBinding
    recordPlan.nestedBindingCount += 1

    ' Let the shared field converter apply each declarator's own pointer,
    ' array, or callback operators to the one inline aggregate type.
    RecordGenericHeaderTypeAliasInHeader( _
        translation.genericC.header, helperName, helperName, "Record")
    Dim declaratorParts() As String
    Dim declaratorCount As Long
    If SplitSimpleCList( _
        fieldDeclarators, declaratorParts(), declaratorCount) = 0 OrElse _
       declaratorCount = 0 Then
        RemoveGenericHeaderTypeAliasInHeader( _
            translation.genericC.header, helperName)
        Return 0
    End If
    Dim commonQualifiers As String
    For declaratorIndex As Long = 0 To declaratorCount - 1
        Dim sourceDeclarator As String = declaratorParts(declaratorIndex)
        If declaratorIndex = 0 Then
            Dim normalizedDeclarator As String = _
                StripCFunctionAttributes(sourceDeclarator)
            Dim qualifierTokens() As String
            Dim qualifierTokenCount As Long
            TokenizeCDeclaration( _
                normalizedDeclarator, qualifierTokens(), qualifierTokenCount)
            Dim firstDeclaratorToken As Long = 0
            While firstDeclaratorToken < qualifierTokenCount
                Select Case qualifierTokens(firstDeclaratorToken)
                Case "const", "volatile", "restrict", "__restrict", "__restrict__"
                    If commonQualifiers <> "" Then commonQualifiers &= " "
                    commonQualifiers &= qualifierTokens(firstDeclaratorToken)
                    firstDeclaratorToken += 1
                Case Else
                    Exit While
                End Select
            Wend
            If firstDeclaratorToken >= qualifierTokenCount Then
                RemoveGenericHeaderTypeAliasInHeader( _
                    translation.genericC.header, helperName)
                Return 0
            End If
            If firstDeclaratorToken > 0 Then
                sourceDeclarator = GenericTokensToText( _
                    qualifierTokens(), firstDeclaratorToken, qualifierTokenCount - 1)
            End If
        End If
        Dim commonType As String = helperName
        If commonQualifiers <> "" Then commonType = commonQualifiers & " " & helperName
        Dim nestedField As GenericRecordField
        If TranslateGenericRecordField( _
            translation, catalog, sourceDeclarator, _
            commonType, 0, ownerTag, ownerAlias, nestedField) = 0 Then
            RemoveGenericHeaderTypeAliasInHeader( _
                translation.genericC.header, helperName)
            Return 0
        End If
        nestedField.itemKind = C2FB_RECORD_BINDING_ITEM_FIELD
        MakeGenericRecordFieldNameUnique( _
            fields(), fieldCount, nestedField, fieldNameIndex)
        AppendGenericRecordField(fields(), fieldCount, nestedField)
    Next
    Return -1
End Function

Declare Function RemoveEmptyGenericRecordAggregates( _
    fields() As GenericRecordField, ByRef fieldCount As Long _
) As Long

Private Function ParseGenericRecordFields( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef declaration As C2fbDeclarationModel, _
    ByRef recordPlan As C2fbGenericRecordPlanModel, _
    outputNames() As String, ByRef outputNameCount As Long, _
    fields() As GenericRecordField, ByRef fieldCount As Long, _
    ByVal ownerTag As String = "", ByVal ownerAlias As String = "" _
) As Long
    ReDim fields(0 To 15)
    fieldCount = 0
    Dim fieldNameIndex As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(fieldNameIndex)
    If declaration.recordFieldsComplete = 0 OrElse _
       declaration.recordFieldCount = 0 Then Return 0

    For sourceFieldIndex As Long = 0 To declaration.recordFieldCount - 1
        With declaration.recordFields(sourceFieldIndex)
            Dim aggregateIsUnion As Long
            Dim aggregateBody As String
            Dim aggregateFieldDeclarators As String
            Dim aggregatePackValue As Long
            If ParseGenericInlineRecordField( _
                .text, aggregateIsUnion, aggregateBody, aggregateFieldDeclarators, _
                aggregatePackValue) <> 0 Then
                If aggregateFieldDeclarators <> "" Then
                    If AppendGenericNamedAggregateField( _
                        translation, catalog, aggregateBody, aggregateIsUnion, _
                        aggregateFieldDeclarators, ownerTag, ownerAlias, 1, recordPlan, _
                        outputNames(), outputNameCount, fields(), fieldCount, _
                        fieldNameIndex) = 0 Then _
                        Return 0
                    Continue For
                End If
                ' GCC accepts anonymous zero-sized nested aggregates. They
                ' declare no promoted fields and occupy no bytes, so omit them
                ' rather than emitting an empty FreeBASIC Type or Union.
                If Trim(aggregateBody) = "" Then Continue For
                Dim parentIsUnion As Long = _
                    CInt(declaration.recordKind = C2FB_RECORD_UNION)
                ' FreeBASIC anonymous aggregates alternate Type and Union. If
                ' C nests the same kind, wrap it in a one-member opposite-kind
                ' aggregate so layout and promoted field offsets remain intact.
                Dim wrapperIsUnion As Long = 0
                If aggregateIsUnion = parentIsUnion Then
                    wrapperIsUnion = CInt(aggregateIsUnion = 0) * -1
                    AppendGenericRecordAggregateMarker( _
                        fields(), fieldCount, _
                        C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN, wrapperIsUnion, _
                        aggregatePackValue)
                End If
                AppendGenericRecordAggregateMarker( _
                    fields(), fieldCount, _
                    C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN, aggregateIsUnion, _
                    aggregatePackValue)
                If ParseGenericRecordNestedFields( _
                    translation, catalog, aggregateBody, ownerTag, ownerAlias, _
                    aggregateIsUnion, 1, recordPlan, outputNames(), _
                    outputNameCount, fields(), fieldCount, fieldNameIndex) = 0 Then Return 0
                AppendGenericRecordAggregateMarker( _
                    fields(), fieldCount, _
                    C2FB_RECORD_BINDING_ITEM_ANONYMOUS_END, aggregateIsUnion)
                If aggregateIsUnion = parentIsUnion Then
                    AppendGenericRecordAggregateMarker( _
                        fields(), fieldCount, _
                        C2FB_RECORD_BINDING_ITEM_ANONYMOUS_END, wrapperIsUnion)
                End If
                Continue For
            End If

            Dim parts() As String
            Dim partCount As Long
            If SplitSimpleCList(.text, parts(), partCount) = 0 OrElse _
               partCount = 0 Then Return 0
            Dim commonType As String
            Dim commonTypeTokenCount As Long = 0
            For partIndex As Long = 0 To partCount - 1
                Dim recordField As GenericRecordField
                Dim translated As Long
                Dim tokenRanges() As C2fbTokenRangeModel
                Dim tokenRangeCount As Long = 0
                Dim sourceRangesReady As Long = 0
                ' Harmless GCC attributes are removed before declaration parsing.
                ' Re-tokenize that normalized text instead of reusing tokens that
                ' still contain an attribute group.
                If InStr(LCase(.text), "__attribute__") = 0 AndAlso _
                   .tokenCount > 0 AndAlso _
                   SplitC2fbTokenList( _
                       .tokens(), 0, .tokenCount - 1, _
                       tokenRanges(), tokenRangeCount) <> 0 AndAlso _
                   tokenRangeCount = partCount Then
                    sourceRangesReady = -1
                End If
                If sourceRangesReady <> 0 Then
                    Dim itemTokens() As String
                    Dim itemTokenCount As Long = 0
                    If BuildC2fbDeclaratorPartTokens( _
                        .tokens(), tokenRanges(), tokenRangeCount, partIndex, _
                        commonTypeTokenCount, itemTokens(), itemTokenCount) = 0 Then _
                        Return 0
                    Dim itemDeclaration As String = parts(partIndex)
                    If partIndex > 0 Then _
                        itemDeclaration = commonType & " " & itemDeclaration
                    translated = TranslateGenericRecordFieldWithTokens( _
                        translation, catalog, parts(partIndex), _
                        StripCFunctionAttributes(itemDeclaration), itemTokens(), _
                        itemTokenCount, commonType, commonTypeTokenCount, _
                        CInt(partIndex = 0), ownerTag, ownerAlias, recordField)
                Else
                    translated = TranslateGenericRecordField( _
                        translation, catalog, parts(partIndex), commonType, _
                        CInt(partIndex = 0), ownerTag, ownerAlias, recordField)
                End If
                If translated = 0 Then
                    recordPlan.unsupportedFieldName = recordField.name
                    Return 0
                End If
                If recordField.isZeroLengthArray <> 0 Then
                    If sourceFieldIndex <> declaration.recordFieldCount - 1 OrElse _
                       partIndex <> partCount - 1 OrElse _
                       declaration.recordKind = C2FB_RECORD_UNION Then
                        recordPlan.unsupportedFieldName = recordField.name
                        Return 0
                    End If
                    If AppendGenericZeroLengthArrayNote( _
                           translation, ownerTag, ownerAlias, _
                           outputNames(), outputNameCount, fields(), fieldCount, _
                           fieldNameIndex, recordField) = 0 Then
                        recordPlan.unsupportedFieldName = recordField.name
                        Return 0
                    End If
                Else
                    recordField.itemKind = C2FB_RECORD_BINDING_ITEM_FIELD
                    MakeGenericRecordFieldNameUnique( _
                        fields(), fieldCount, recordField, fieldNameIndex)
                    AppendGenericRecordField(fields(), fieldCount, recordField)
                End If
            Next
        End With
    Next
    Dim rootPackingCap As Long = declaration.packValue
    If declaration.isPacked <> 0 Then rootPackingCap = 1
    If RemoveEmptyGenericRecordAggregates(fields(), fieldCount) = 0 Then Return 0
    If ValidateGenericRecordFieldItems( _
        translation, fields(), fieldCount, _
        CInt(declaration.recordKind = C2FB_RECORD_UNION) * -1, _
        rootPackingCap) = 0 Then Return 0
    Return -1
End Function

Private Function RemoveEmptyGenericRecordAggregates( _
    fields() As GenericRecordField, ByRef fieldCount As Long _
) As Long
    If fieldCount <= 0 Then Return -1
    Dim compacted() As GenericRecordField
    ReDim compacted(0 To fieldCount - 1)
    Dim blockStarts(0 To MAX_GENERIC_RECORD_OUTPUT_NESTING) As Long
    Dim blockHasFields(0 To MAX_GENERIC_RECORD_OUTPUT_NESTING) As Long
    Dim nestingDepth As Long = 0
    Dim compactedCount As Long = 0

    For itemIndex As Long = 0 To fieldCount - 1
        Select Case fields(itemIndex).itemKind
        Case C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN
            If nestingDepth >= MAX_GENERIC_RECORD_OUTPUT_NESTING Then Return 0
            nestingDepth += 1
            blockStarts(nestingDepth) = compactedCount
            blockHasFields(nestingDepth) = 0
            compacted(compactedCount) = fields(itemIndex)
            compactedCount += 1
        Case C2FB_RECORD_BINDING_ITEM_ANONYMOUS_END
            If nestingDepth <= 0 Then Return 0
            If blockHasFields(nestingDepth) <> 0 Then
                compacted(compactedCount) = fields(itemIndex)
                compactedCount += 1
            Else
                compactedCount = blockStarts(nestingDepth)
            End If
            nestingDepth -= 1
        Case C2FB_RECORD_BINDING_ITEM_FIELD, C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY
            compacted(compactedCount) = fields(itemIndex)
            compactedCount += 1
            For blockIndex As Long = 1 To nestingDepth
                blockHasFields(blockIndex) = -1
            Next
        Case Else
            Return 0
        End Select
    Next
    If nestingDepth <> 0 Then Return 0
    For itemIndex As Long = 0 To compactedCount - 1
        fields(itemIndex) = compacted(itemIndex)
    Next
    fieldCount = compactedCount
    Return -1
End Function

/' ------------------------------------------------------------------------- '/
/' Record layout emission                                                  '/
/' ------------------------------------------------------------------------- '/

Private Function GenericDeferredCallbackFieldType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal fieldType As String _
) As String
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(fieldType, tokens(), tokenCount)
    For tokenIndex As Long = 0 To tokenCount - 1
        For aliasIndex As Long = 0 To _
            translation.genericC.header.headerTypeAliasCount - 1
            With translation.genericC.header.headerTypeAliases(aliasIndex)
                If .isFunction = 0 OrElse .deferredAfterRecords = 0 Then _
                    Continue For
                If tokens(tokenIndex) = .freeBasicName Then Return "Any Ptr"
            End With
        Next
    Next
    Return fieldType
End Function

Private Sub MakeDeferredCallbackRecordFieldsOpaque( _
    ByRef translation As C2fbTranslationContext, _
    ByRef recordBinding As C2fbRecordBindingModel _
)
    ' Indirect callback calls are outside the body subset. A record field for
    ' a callback deferred until after layouts only needs pointer-sized storage.
    For itemIndex As Long = 0 To recordBinding.itemCount - 1
        With recordBinding.items(itemIndex)
            If .kind <> C2FB_RECORD_BINDING_ITEM_FIELD Then Continue For
            Dim fieldType As String = GenericDeferredCallbackFieldType( _
                translation, .fieldType)
            If fieldType <> .fieldType Then
                .fieldType = fieldType
                .alignmentStorageType = fieldType
            End If
        End With
    Next
    For fieldIndex As Long = 0 To recordBinding.fieldCount - 1
        With recordBinding.fields(fieldIndex)
            Dim fieldType As String = GenericDeferredCallbackFieldType( _
                translation, .fieldType)
            If fieldType <> .fieldType Then
                .fieldType = fieldType
                .alignmentStorageType = fieldType
            End If
        End With
    Next
End Sub

Private Sub WriteGenericHeaderRecords( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For entryIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(entryIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               .recordKind = C2FB_RECORD_ENUM Then Continue For
            If .removeFromGenericHeader <> 0 Then Continue For
            If GenericSourceIncludedInPolicy( _
                translation.genericC.policy, .sourceSpan.startLocation.path) = 0 Then _
                Continue For
            RequireGenericRecordPlan(translation, entryIndex)
            Dim plan As C2fbGenericRecordPlanModel = _
                translation.genericC.header.recordPlans(entryIndex)
            If plan.isExcluded <> 0 Then
                EmitC2fbSkippedAtLocation(translation, outputFile, conversionSummary, _
                    "excluded record type", _
                    IIf(.recordTag <> "", .recordTag, .recordAlias), _
                    .sourceSpan.startLocation)
                Continue For
            End If
            If plan.isOpaqueEmpty <> 0 Then Continue For
            If plan.isSupported = 0 Then
                Dim recordName As String = _
                    IIf(.recordTag <> "", .recordTag, .recordAlias)
                If plan.unsupportedFieldName <> "" Then _
                    recordName &= " (field " & plan.unsupportedFieldName & ")"
                EmitC2fbSkippedAtLocation(translation, _
                    outputFile, conversionSummary, "unsupported record declaration/layout", _
                    recordName, _
                    .sourceSpan.startLocation)
                Continue For
            End If
            If plan.freeBasicName = "" OrElse plan.implementationName = "" Then Continue For
            If plan.bindingReady = 0 Then
                EmitC2fbSkippedAtLocation(translation, outputFile, conversionSummary, "unsupported record layout", _
                    IIf(.recordTag <> "", .recordTag, .recordAlias), _
                    .sourceSpan.startLocation)
                Continue For
            End If
            For nestedBindingIndex As Long = 0 To plan.nestedBindingCount - 1
                MakeDeferredCallbackRecordFieldsOpaque( _
                    translation, plan.nestedBindings(nestedBindingIndex))
                WriteC2fbRecordBinding( _
                    outputFile, plan.nestedBindings(nestedBindingIndex), _
                    plan.ifndefGuardName, plan.undefBeforeName)
                conversionSummary.genericHeader.recordLayoutCount += 1
            Next
            ' FreeBASIC defaults to the target C ABI. FIELD = N caps both
            ' member alignment and trailing record padding for packed layouts.
            MakeDeferredCallbackRecordFieldsOpaque(translation, plan.binding)
            WriteC2fbRecordBinding( _
                outputFile, plan.binding, plan.ifndefGuardName, "")
            conversionSummary.genericHeader.recordLayoutCount += 1
        End With
    Next
End Sub

/' end of c2fb_generic_records.bi '/
