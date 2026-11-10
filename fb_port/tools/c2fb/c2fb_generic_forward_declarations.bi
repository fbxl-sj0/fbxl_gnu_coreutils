/'
    Project: C2FB generic header converter

    File: c2fb_generic_forward_declarations.bi

    Purpose:

        Preserve selected incomplete C struct and union tags as FreeBASIC
        forward type aliases.

    Responsibilities:

        - Find selected tags and simple typedef aliases in collected declarations.
        - Reuse complete record types when their layouts will be emitted.
        - Create FreeBASIC forward references for pointer-only declarations.
        - Emit and audit requested forward aliases before procedures and objects.

    This file intentionally does NOT contain:

        - Record field parsing or ABI layout validation.
        - C preprocessor execution or command-line tokenization.
'/

Private Sub AddGenericForwardTypeNameToLists( _
    ByVal freeBasicName As String, typeNames() As String, _
    ByRef typeNameCount As Long, outputNames() As String, _
    ByRef outputNameCount As Long _
)
    If C2fbNameListContains(typeNames(), typeNameCount, freeBasicName) = 0 Then
        If typeNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
            ReportError("generic header exceeds the configured forward type limit")
        If typeNameCount > UBound(typeNames) Then _
            ReDim Preserve typeNames(0 To UBound(typeNames) * 2 + 1)
        typeNames(typeNameCount) = freeBasicName
        typeNameCount += 1
    End If
    If C2fbNameListContains(outputNames(), outputNameCount, freeBasicName) = 0 Then
        If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
            ReportError("generic header exceeds the configured forward type limit")
        If outputNameCount > UBound(outputNames) Then _
            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
        outputNames(outputNameCount) = freeBasicName
        outputNameCount += 1
    End If
End Sub

Private Function GenericForwardRecordPlanIndex( _
    ByRef translation As C2fbTranslationContext, ByVal tagName As String _
) As Long
    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind = C2FB_DECLARATION_RECORD AndAlso _
               (.recordKind = C2FB_RECORD_STRUCT OrElse _
                .recordKind = C2FB_RECORD_UNION) AndAlso _
               .recordTag = tagName Then Return declarationIndex
        End With
    Next
    Return -1
End Function

Private Sub PrepareOneGenericForwardDeclaration( _
    ByRef translation As C2fbTranslationContext, _
    ByVal tagName As String, ByVal aliasName As String, _
    typeNames() As String, ByRef typeNameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByVal afterLayoutValidation As Long _
)
    If tagName = "" Then Exit Sub
    If GenericTypeExcludedInPolicy(translation.genericC.policy, tagName) <> 0 OrElse _
       (aliasName <> "" AndAlso GenericTypeExcludedInPolicy( _
            translation.genericC.policy, aliasName) <> 0) Then Exit Sub
    If MarkGenericForwardDeclarationRequestedInPolicy( _
        translation.genericC.policy, tagName, aliasName) = 0 Then Exit Sub

    Dim tagIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, tagName, -1)
    Dim completePlanIndex As Long = _
        GenericForwardRecordPlanIndex(translation, tagName)
    Dim completeTypeAvailable As Long = 0
    Dim tagAlreadyForward As Long = 0
    Dim forwardTargetName As String
    Dim freeBasicTagName As String
    If completePlanIndex >= 0 Then
        Dim completePlan As C2fbGenericRecordPlanModel = _
            translation.genericC.header.recordPlans(completePlanIndex)
        If completePlan.isExcluded = 0 AndAlso completePlan.isSupported <> 0 AndAlso _
           (afterLayoutValidation = 0 OrElse completePlan.bindingReady <> 0) AndAlso _
           GenericSourceIncludedInPolicy( _
                translation.genericC.policy, _
                translation.sourceUnit.declarations( _
                    completePlanIndex).sourceSpan.startLocation.path) <> 0 Then
            completeTypeAvailable = -1
        End If
        freeBasicTagName = completePlan.freeBasicName
        forwardTargetName = completePlan.implementationName
    End If

    If tagIndex >= 0 Then
        If freeBasicTagName = "" Then _
            freeBasicTagName = _
                translation.genericC.header.headerTypeAliases(tagIndex).freeBasicName
        If translation.genericC.header.headerTypeAliases(tagIndex).isForward <> 0 Then
            tagAlreadyForward = -1
            forwardTargetName = _
                translation.genericC.header.headerTypeAliases(tagIndex).baseType
        End If
    End If

    If completeTypeAvailable <> 0 AndAlso tagIndex >= 0 Then
        ' A scanned C forward declaration becomes a complete BASIC type once
        ' its layout has passed validation.
        translation.genericC.header.headerTypeAliases(tagIndex).isForward = 0
        tagAlreadyForward = 0
    End If
    Dim forwardAliasFlag As Long = CInt(completeTypeAvailable = 0) * -1

    If completeTypeAvailable <> 0 AndAlso tagAlreadyForward = 0 AndAlso _
       (aliasName = "" OrElse aliasName <> tagName) Then Exit Sub

    If freeBasicTagName = "" Then
        Dim ordinaryTagIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, tagName, 0)
        If ordinaryTagIndex >= 0 Then
            freeBasicTagName = _
                translation.genericC.header.headerTypeAliases(ordinaryTagIndex).freeBasicName
        Else
            freeBasicTagName = GenericFreeBasicTypeNameInPolicy( _
                translation, tagName, typeNames(), typeNameCount, _
                outputNames(), outputNameCount, C2FB_SYMBOL_RENAME_TAG)
            AddGenericForwardTypeNameToLists( _
                freeBasicTagName, typeNames(), typeNameCount, _
                outputNames(), outputNameCount)
        End If
    End If
    If forwardTargetName = "" Then _
        forwardTargetName = "_" & translation.genericC.policy.generatedNamePrefix & _
            "record_" & freeBasicTagName

    If tagIndex >= 0 AndAlso tagAlreadyForward = 0 Then
        With translation.genericC.header.headerTypeAliases(tagIndex)
            .freeBasicName = freeBasicTagName
            .baseType = forwardTargetName
            .emitted = 0
            .isForward = forwardAliasFlag
        End With
    ElseIf tagIndex < 0 Then
        RecordGenericHeaderTypeAliasInHeader( _
            translation.genericC.header, tagName, freeBasicTagName, _
            forwardTargetName, 0, -1, 0, 0, "", 0, forwardAliasFlag)
    End If

    If aliasName <> "" Then
        Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, aliasName, 0)
        If aliasName = tagName Then
            If GenericTypedefExpansionRequestedInPolicy( _
                translation.genericC.policy, aliasName) <> 0 Then _
                MarkGenericTypedefExpansionMatchedInPolicy( _
                    translation.genericC.policy, aliasName)
            Dim freeBasicAliasName As String
            If aliasIndex >= 0 Then
                freeBasicAliasName = translation.genericC.header.headerTypeAliases( _
                    aliasIndex).freeBasicName
            ElseIf completePlanIndex >= 0 AndAlso _
                   translation.genericC.header.recordPlans( _
                       completePlanIndex).aliasFreeBasicName <> "" Then
                ' Layout validation can remove this alias before the second
                ' forward pass. Reuse its first-pass name so record fields
                ' keep resolving to the same typedef identifier.
                freeBasicAliasName = translation.genericC.header.recordPlans( _
                    completePlanIndex).aliasFreeBasicName
            Else
                freeBasicAliasName = GenericFreeBasicTypeNameInPolicy( _
                    translation, aliasName, typeNames(), typeNameCount, _
                    outputNames(), outputNameCount)
            End If

            If freeBasicAliasName = freeBasicTagName Then
                freeBasicAliasName &= "_"
            End If
            Do
                Dim aliasNameConflict As Long = 0
                Dim existingTypeAliasIndex As Long = _
                    GenericHeaderTypeAliasIndexByFreeBasicNameInHeader( _
                        translation.genericC.header, freeBasicAliasName)
                If existingTypeAliasIndex >= 0 AndAlso _
                   translation.genericC.header.headerTypeAliases( _
                       existingTypeAliasIndex).sourceName <> aliasName Then
                    aliasNameConflict = -1
                End If
                If C2fbNameListContains( _
                    outputNames(), outputNameCount, freeBasicAliasName) <> 0 AndAlso _
                   C2fbNameListContains( _
                    typeNames(), typeNameCount, freeBasicAliasName) = 0 Then
                    aliasNameConflict = -1
                End If
                If aliasNameConflict = 0 Then Exit Do
                    freeBasicAliasName &= "_"
            Loop
            If completePlanIndex >= 0 Then _
                translation.genericC.header.recordPlans( _
                    completePlanIndex).aliasFreeBasicName = freeBasicAliasName
            AddGenericForwardTypeNameToLists( _
                freeBasicAliasName, typeNames(), typeNameCount, _
                outputNames(), outputNameCount)
            If aliasIndex >= 0 Then
                ' Keep the typedef's separate FreeBASIC name. Record fields
                ' may already refer to it even when the tag layout is opaque.
                With translation.genericC.header.headerTypeAliases(aliasIndex)
                    .freeBasicName = freeBasicAliasName
                    .baseType = freeBasicTagName
                    .emitted = 0
                    .isForward = forwardAliasFlag
                End With
            Else
                RecordGenericHeaderTypeAliasInHeader( _
                    translation.genericC.header, aliasName, _
                    freeBasicAliasName, freeBasicTagName, 0, 0, 0, 0, "", 0, _
                    forwardAliasFlag)
            End If
        Else
            Dim expandAlias As Long = _
                GenericTypedefExpansionRequestedInPolicy( _
                    translation.genericC.policy, aliasName)
            If expandAlias <> 0 Then
                If aliasIndex >= 0 Then
                    With translation.genericC.header.headerTypeAliases(aliasIndex)
                        .freeBasicName = freeBasicTagName
                        .baseType = ""
                        .emitted = -1
                        .isForward = -1
                    End With
                Else
                    RecordGenericHeaderTypeAliasInHeader( _
                        translation.genericC.header, aliasName, _
                        freeBasicTagName, "", -1, 0, 0, 0, "", 0, -1)
                End If
                MarkGenericTypedefExpansionMatchedInPolicy( _
                    translation.genericC.policy, aliasName)
            Else
                Dim freeBasicAliasName As String
                If aliasIndex >= 0 Then
                    freeBasicAliasName = _
                        translation.genericC.header.headerTypeAliases(aliasIndex).freeBasicName
                Else
                    freeBasicAliasName = GenericFreeBasicTypeNameInPolicy( _
                        translation, aliasName, typeNames(), typeNameCount, _
                        outputNames(), outputNameCount)
                    AddGenericForwardTypeNameToLists( _
                        freeBasicAliasName, typeNames(), typeNameCount, _
                        outputNames(), outputNameCount)
                End If
                If aliasIndex >= 0 Then
                    With translation.genericC.header.headerTypeAliases(aliasIndex)
                        .freeBasicName = freeBasicAliasName
                        .baseType = freeBasicTagName
                        .emitted = 0
                        .isForward = -1
                    End With
                Else
                    RecordGenericHeaderTypeAliasInHeader( _
                        translation.genericC.header, aliasName, _
                        freeBasicAliasName, freeBasicTagName, 0, 0, 0, 0, "", 0, -1)
                End If
            End If
        End If
    End If
    MarkGenericForwardDeclarationRequestedInPolicy( _
        translation.genericC.policy, tagName, aliasName)
End Sub

Private Sub PrepareGenericHeaderForwardDeclarations( _
    ByRef translation As C2fbTranslationContext, _
    typeNames() As String, ByRef typeNameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByVal afterLayoutValidation As Long = 0 _
)
    If translation.genericC.policy.forwardDeclarationPatternCount = 0 Then Exit Sub
    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind = C2FB_DECLARATION_RECORD Then
                If .removeFromGenericHeader <> 0 Then Continue For
                If .recordKind = C2FB_RECORD_STRUCT OrElse _
                   .recordKind = C2FB_RECORD_UNION Then
                    PrepareOneGenericForwardDeclaration( _
                        translation, .recordTag, .recordAlias, _
                        typeNames(), typeNameCount, outputNames(), outputNameCount, _
                        afterLayoutValidation)
                End If
                Continue For
            End If
            Dim declarationText As String = StripCFunctionAttributes(.text)
            Dim tokens() As String
            Dim tokenCount As Long
            TokenizeCDeclaration(declarationText, tokens(), tokenCount)
            If tokenCount = 0 Then Continue For
            Dim lastToken As Long = tokenCount - 1
            If tokens(lastToken) = ";" Then lastToken -= 1
            Dim isTypedef As Long = CInt(tokens(0) = "typedef")
            For tokenIndex As Long = 0 To lastToken - 1
                Dim recordKind As C2fbRecordKind = C2FB_RECORD_KIND_NONE
                Select Case tokens(tokenIndex)
                Case "struct": recordKind = C2FB_RECORD_STRUCT
                Case "union": recordKind = C2FB_RECORD_UNION
                Case Else: Continue For
                End Select
                If IsIdentifierToken(tokens(tokenIndex + 1)) = 0 Then Continue For
                Dim aliasName As String
                If isTypedef <> 0 AndAlso tokenIndex + 2 = lastToken AndAlso _
                   IsIdentifierToken(tokens(tokenIndex + 2)) <> 0 Then _
                    aliasName = tokens(tokenIndex + 2)
                PrepareOneGenericForwardDeclaration( _
                    translation, tokens(tokenIndex + 1), aliasName, _
                    typeNames(), typeNameCount, outputNames(), outputNameCount, _
                    afterLayoutValidation)
            Next
        End With
    Next
    ' Forward lowering can assign a distinct BASIC typedef name after the
    ' record pass, so refresh the lookup maps before type consumers run.
    RebuildGenericHeaderTypeAliasIndex(translation.genericC.header)
End Sub

Private Sub WriteGenericHeaderForwardDeclarations( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    For aliasIndex As Long = 0 To _
        translation.genericC.header.headerTypeAliasCount - 1
        With translation.genericC.header.headerTypeAliases(aliasIndex)
            If .isForward = 0 OrElse .emitted <> 0 Then Continue For
            Dim typeAlias As C2fbTypeAliasBindingModel
            typeAlias.freeBasicName = .freeBasicName
            typeAlias.targetType = .baseType
            Dim ifndefGuardName As String = _
                GenericDeclarationIfndefGuardNameInPolicy( _
                    translation.genericC.policy, .sourceName, .freeBasicName)
            Dim undefBeforeName As String = _
                GenericDeclarationUndefBeforeNameInPolicy( _
                    translation.genericC.policy, .sourceName, .freeBasicName)
            WriteC2fbTypeAlias( _
                outputFile, typeAlias, ifndefGuardName, undefBeforeName)
            .emitted = -1
        End With
    Next
    If translation.genericC.policy.forwardDeclarationPatternCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Sub WriteGenericForwardDeclarationReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.forwardDeclarationPatternCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb forward declaration requests:")
    For patternIndex As Long = 0 To policy.forwardDeclarationPatternCount - 1
        Dim stateText As String = "unused"
        If policy.forwardDeclarationPatterns(patternIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb add-forward-decl " & _
            stateText & ": " & policy.forwardDeclarationPatterns(patternIndex).pattern)
    Next
End Sub

/' end of c2fb_generic_forward_declarations.bi '/
