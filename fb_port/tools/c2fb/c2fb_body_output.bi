/'
    Project: C2FB

    File: c2fb_body_output.bi

    Purpose:

        Write a body-candidate module from lowered candidate models.

    Responsibilities:

        - Format the candidate-file header and target-specific includes.
        - Emit ABI aliases, declarations, callbacks, private static storage, and candidates.
        - Keep callback aliases used by external callable objects in the module.
        - Include SQLite-generated API declarations only for SQLite targets.
        - Keep discovered FreeBASIC project headers available to generic targets.
        - Avoid duplicate C and FreeBASIC prototypes for the same helper.
        - Select project declarations and includes from the indexed FreeBASIC catalog.
        - Emit runtime helper declarations from the shared body symbol table.
        - Report rejected candidates through the shared diagnostic model.
        - Summarize generated candidates without inspecting C source syntax.

    This file intentionally does NOT contain:

        - C preprocessing, declaration collection, or statement lowering.
        - Target type resolution or symbol indexing.
'/

Private Type C2fbBodyCandidateFileModel
    outputPath As String
    sourceLabel As String
    fbSourceDirectory As String
    keepUnresolvedDependencies As Long
    assertionsStripped As Long
End Type

Declare Function C2fbCallbackUsesGeneratedRecordByValue( _
    ByRef translation As C2fbTranslationContext, _
    ByVal callbackIndex As Long, generatedRecordIsUsed() As Long _
) As Long

Private Function C2fbBodyCandidateWillBeEmitted( _
    ByRef candidate As C2fbBodyCandidateModel _
) As Long
    Return CInt(candidate.source <> "" AndAlso _
                candidate.duplicate = 0 AndAlso _
                candidate.skipMessage = "") * -1
End Function

Private Sub WriteCBodyAbiTypeAliases( _
    ByRef translation As C2fbTranslationContext, _
    ByRef fileOutput As C2fbGeneratedFileOutputModel _
)
    Dim guardModel As C2fbGeneratedFileGuardModel
    If BeginC2fbGeneratedFileGuard( _
        fileOutput, guardModel, "__C2FB_BODY_C_ABI_TYPES__") = 0 Then _
        ReportError("cannot open the body ABI type include guard")
    WriteC2fbAbiTypeAliases(translation, fileOutput)
    If EndC2fbGeneratedFileGuard(fileOutput, guardModel) = 0 Then _
        ReportError("cannot close the body ABI type include guard")
End Sub

Private Function CBodyCallbackOutputDeclaration( _
    ByRef translation As C2fbTranslationContext, _
    ByVal declaration As String _
) As String
    Dim result As String
    Dim position As Long = 1
    While position <= Len(declaration)
        Dim replacementLength As Long = 0
        For recordIndex As Long = 0 To translation.body.recordBindingCount - 1
            With translation.body.recordBindings(recordIndex)
                If .isGenerated = 0 OrElse .fbName = "" OrElse _
                   position + Len(.fbName) - 1 > Len(declaration) OrElse _
                   Mid(declaration, position, Len(.fbName)) <> .fbName Then _
                    Continue For
                Dim beforeByte As Long = 0
                Dim afterPosition As Long = position + Len(.fbName)
                Dim afterByte As Long = 0
                If position > 1 Then beforeByte = Asc(declaration, position - 1)
                If afterPosition <= Len(declaration) Then _
                    afterByte = Asc(declaration, afterPosition)
                If (beforeByte <> 0 AndAlso IsIdentifierPart(beforeByte) <> 0) OrElse _
                   (afterByte <> 0 AndAlso IsIdentifierPart(afterByte) <> 0) Then _
                    Continue For

                Dim pointerPosition As Long = afterPosition
                While pointerPosition <= Len(declaration) AndAlso _
                      IsSpaceByte(Asc(declaration, pointerPosition)) <> 0
                    pointerPosition += 1
                Wend
                If LCase(Mid(declaration, pointerPosition, 3)) <> "ptr" Then _
                    Continue For

                ' Public callback aliases cannot expose private source UDTs.
                ' All object pointers have the same C ABI representation.
                replacementLength = Len(.fbName)
                Exit For
            End With
        Next
        If replacementLength <> 0 Then
            result &= "Any"
            position += replacementLength
        Else
            result &= Chr(Asc(declaration, position))
            position += 1
        End If
    Wend
    Return result
End Function

Private Sub WriteCBodyCallbackDeclarations( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    candidates() As C2fbBodyCandidateModel, _
    ByVal candidateCount As Long, generatedRecordIsUsed() As Long, _
    ByVal afterGeneratedRecords As Long = 0 _
)
    Dim wroteDeclaration As Long = 0
    If translation.body.callbackCount <= 0 Then Exit Sub

    Dim callbackUsedByExternalDeclaration(Any) As Long
    ReDim callbackUsedByExternalDeclaration( _
        0 To translation.body.callbackCount - 1)
    ' Index callback type spellings once; large system headers can contain
    ' thousands of aliases, and linear lookup inside dependency closure scales
    ' poorly for those translation units.
    Dim callbackIndexByType As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(callbackIndexByType)
    For callbackIndex As Long = 0 To translation.body.callbackCount - 1
        With translation.body.callbacks(callbackIndex)
            If AddC2fbStringIndexMapEntry( _
                callbackIndexByType, .fbType, callbackIndex) = 0 Then _
                ReportError("callback type index exceeds its configured limit")
            If .declaration <> .fbType AndAlso _
               AddC2fbStringIndexMapEntry( _
                   callbackIndexByType, .declaration, callbackIndex) = 0 Then _
                ReportError("callback declaration index exceeds its configured limit")
        End With
    Next
    For procedureIndex As Long = 0 To _
        translation.symbolTable.symbolCount - 1
        With translation.symbolTable.symbols(procedureIndex)
            If .ambiguous <> 0 OrElse .body.isAmbiguous <> 0 OrElse _
               (.body.isExternal = 0 AndAlso _
                (.body.isRuntime = 0 OrElse .body.isDeclared = 0)) Then _
                Continue For

            Dim procedureIsUsed As Long = 0
            Dim freeBasicName As String = _
                CBodySymbolFreeBasicName(translation, catalog, procedureIndex)
            For candidateIndex As Long = 0 To candidateCount - 1
                If candidates(candidateIndex).source = "" OrElse _
                   candidates(candidateIndex).duplicate <> 0 OrElse _
                   candidates(candidateIndex).skipMessage <> "" Then Continue For
                If CBodyUsesProcedure( _
                    candidates(candidateIndex).source, freeBasicName) <> 0 OrElse _
                   CBodyUsesProcedure( _
                    candidates(candidateIndex).source, .sourceName) <> 0 Then
                    procedureIsUsed = -1
                    Exit For
                End If
            Next
            If procedureIsUsed = 0 Then Continue For

            Dim returnCallbackIndex As Long = _
                C2fbStringIndexMapLookup( _
                    callbackIndexByType, .body.returnType)
            If returnCallbackIndex >= 0 Then _
                callbackUsedByExternalDeclaration(returnCallbackIndex) = -1
            For parameterIndex As Long = 0 To .body.parameterCount - 1
                Dim parameterCallbackIndex As Long = _
                    C2fbStringIndexMapLookup( _
                        callbackIndexByType, CBodyParameterType( _
                            translation, catalog, .sourceName, parameterIndex))
                If parameterCallbackIndex >= 0 Then _
                    callbackUsedByExternalDeclaration(parameterCallbackIndex) = -1
            Next
        End With
    Next

    ' Callback aliases used by candidate signatures can depend on other
    ' callback aliases. Seed directly from emitted declarations, globals, and
    ' used generated records before walking those dependencies.
    For candidateIndex As Long = 0 To candidateCount - 1
        If C2fbBodyCandidateWillBeEmitted( _
            candidates(candidateIndex)) = 0 Then Continue For
        For callbackIndex As Long = 0 To translation.body.callbackCount - 1
            If InStr(candidates(candidateIndex).source, _
                     translation.body.callbacks(callbackIndex).fbType) <> 0 Then _
                callbackUsedByExternalDeclaration(callbackIndex) = -1
        Next
    Next

    If translation.body.includeGlobalDefinitions <> 0 Then
        For objectIndex As Long = 0 To _
            translation.body.externalObjectCount - 1
            With translation.body.externalObjects(objectIndex)
                If .isAmbiguous <> 0 OrElse .isReused <> 0 OrElse _
                   .isDefinition = 0 Then Continue For
                Dim callbackIndex As Long = C2fbStringIndexMapLookup( _
                    callbackIndexByType, .freeBasicType)
                If callbackIndex >= 0 Then _
                    callbackUsedByExternalDeclaration(callbackIndex) = -1
            End With
        Next
    End If

    For candidateIndex As Long = 0 To candidateCount - 1
        If C2fbBodyCandidateWillBeEmitted( _
            candidates(candidateIndex)) = 0 Then Continue For
        For objectIndex As Long = 0 To _
            translation.body.externalObjectCount - 1
            With translation.body.externalObjects(objectIndex)
                Dim callbackIndex As Long = C2fbStringIndexMapLookup( _
                    callbackIndexByType, .freeBasicType)
                If callbackIndex < 0 Then Continue For
                If InStr(candidates(candidateIndex).source, .freeBasicName) <> 0 OrElse _
                   CBodyUsesIdentifier( _
                       candidates(candidateIndex).source, .sourceName) <> 0 Then _
                    callbackUsedByExternalDeclaration(callbackIndex) = -1
            End With
        Next
    Next

    Dim generatedRecordBindingByName As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(generatedRecordBindingByName)
    For bindingIndex As Long = 0 To _
        translation.body.recordBindingCount - 1
        With translation.body.recordBindings(bindingIndex)
            If generatedRecordIsUsed(bindingIndex) = 0 OrElse _
               .isGenerated = 0 OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) Then Continue For
            If AddC2fbStringIndexMapEntry( _
                generatedRecordBindingByName, .sourceName, bindingIndex) = 0 Then _
                ReportError("generated callback-record index exceeds its configured limit")
        End With
    Next
    For fieldIndex As Long = 0 To translation.body.recordFieldCount - 1
        With translation.body.recordFields(fieldIndex)
            Dim bindingIndex As Long = C2fbStringIndexMapLookup( _
                generatedRecordBindingByName, .ownerName)
            If bindingIndex < 0 Then Continue For
            Dim fieldCallbackType As String = .callbackType
            If fieldCallbackType = "" Then _
                fieldCallbackType = LookupCBodyCallbackTypeAlias( _
                    translation, .sourceType)
            Dim callbackIndex As Long = C2fbStringIndexMapLookup( _
                callbackIndexByType, fieldCallbackType)
            If callbackIndex >= 0 Then _
                callbackUsedByExternalDeclaration(callbackIndex) = -1
        End With
    Next

    ' Walk only aliases reached from declarations instead of rescanning the
    ' complete callback catalog once per dependency layer.
    Dim callbackDependencyQueue(Any) As Long
    ReDim callbackDependencyQueue(0 To translation.body.callbackCount - 1)
    Dim callbackQueueCount As Long = 0
    Dim callbackQueueRead As Long = 0
    For callbackIndex As Long = 0 To translation.body.callbackCount - 1
        If callbackUsedByExternalDeclaration(callbackIndex) = 0 Then Continue For
        callbackDependencyQueue(callbackQueueCount) = callbackIndex
        callbackQueueCount += 1
    Next
    While callbackQueueRead < callbackQueueCount
        Dim callbackIndex As Long = _
            callbackDependencyQueue(callbackQueueRead)
        callbackQueueRead += 1
        Dim dependencyIndex As Long = C2fbStringIndexMapLookup( _
            callbackIndexByType, _
            translation.body.callbacks(callbackIndex).returnType)
        If dependencyIndex >= 0 AndAlso _
           callbackUsedByExternalDeclaration(dependencyIndex) = 0 Then
            callbackUsedByExternalDeclaration(dependencyIndex) = -1
            If callbackQueueCount >= translation.body.callbackCount Then
                ReportError("callback dependency queue exceeds its configured limit")
                Exit Sub
            End If
            callbackDependencyQueue(callbackQueueCount) = dependencyIndex
            callbackQueueCount += 1
        End If
        For parameterIndex As Long = 0 To _
            translation.body.callbacks(callbackIndex).parameterCount - 1
            Dim parameterType As String = _
                CBodyCallbackParameterTypeAtIndexInContext( _
                    translation, callbackIndex, parameterIndex)
            While Right(parameterType, 4) = " Ptr"
                parameterType = Left(parameterType, Len(parameterType) - 4)
            Wend
            If Left(parameterType, 6) = "Const " Then _
                parameterType = Mid(parameterType, 7)
            dependencyIndex = C2fbStringIndexMapLookup( _
                callbackIndexByType, parameterType)
            If dependencyIndex >= 0 AndAlso _
               callbackUsedByExternalDeclaration(dependencyIndex) = 0 Then
                callbackUsedByExternalDeclaration(dependencyIndex) = -1
                If callbackQueueCount >= translation.body.callbackCount Then
                    ReportError("callback dependency queue exceeds its configured limit")
                    Exit Sub
                End If
                callbackDependencyQueue(callbackQueueCount) = dependencyIndex
                callbackQueueCount += 1
            End If
        Next
    Wend

    For callbackIndex As Long = 0 To translation.body.callbackCount - 1
        If callbackUsedByExternalDeclaration(callbackIndex) = 0 Then Continue For
        Dim requiresGeneratedRecord As Long = _
            C2fbCallbackUsesGeneratedRecordByValue( _
                translation, callbackIndex, generatedRecordIsUsed())
        If CInt(afterGeneratedRecords <> 0) <> requiresGeneratedRecord Then _
            Continue For
        Dim callbackAlias As C2fbTypeAliasBindingModel
        callbackAlias.freeBasicName = translation.body.callbacks(callbackIndex).fbType
        callbackAlias.targetType = CBodyCallbackOutputDeclaration( _
            translation, translation.body.callbacks(callbackIndex).declaration)
        WriteC2fbTypeAlias(outputFile, callbackAlias)
        wroteDeclaration = -1
    Next
    If wroteDeclaration <> 0 Then WriteC2fbOutputLine(outputFile, "")
End Sub

Private Function C2fbBodyTypeNamesGeneratedRecordValue( _
    ByVal typeName As String, ByVal recordName As String _
) As Long
    typeName = Trim(typeName)
    If Left(typeName, 6) = "Const " Then typeName = Trim(Mid(typeName, 7))
    Return CInt(LCase(typeName) = LCase(recordName)) * -1
End Function

Private Function C2fbCallbackUsesRecordName( _
    ByRef translation As C2fbTranslationContext, _
    ByVal callbackIndex As Long, ByVal recordName As String _
) As Long
    With translation.body.callbacks(callbackIndex)
        If C2fbBodyTypeNamesGeneratedRecordValue( _
            .returnType, recordName) <> 0 Then Return -1
        For parameterIndex As Long = 0 To .parameterCount - 1
            Dim parameterType As String = _
                CBodyCallbackParameterTypeInContext( _
                    translation, .fbType, parameterIndex)
            If C2fbBodyTypeNamesGeneratedRecordValue( _
                parameterType, recordName) <> 0 Then Return -1
        Next
    End With
    Return 0
End Function

Private Function C2fbCallbackUsesGeneratedRecordByValue( _
    ByRef translation As C2fbTranslationContext, _
    ByVal callbackIndex As Long, generatedRecordIsUsed() As Long _
) As Long
    With translation.body.callbacks(callbackIndex)
        For bindingIndex As Long = 0 To _
            translation.body.recordBindingCount - 1
            If generatedRecordIsUsed(bindingIndex) = 0 OrElse _
               translation.body.recordBindings(bindingIndex).isGenerated = 0 OrElse _
               (translation.body.recordBindings(bindingIndex).recordKind <> _
                    C2FB_RECORD_STRUCT AndAlso _
                translation.body.recordBindings(bindingIndex).recordKind <> _
                    C2FB_RECORD_UNION) Then Continue For
            If C2fbCallbackUsesRecordName( _
                translation, callbackIndex, _
                translation.body.recordBindings(bindingIndex).fbName) <> 0 Then _
                Return -1
        Next
    End With
    Return 0
End Function

Private Sub IndexCBodyGeneratedLocalRecordUsage( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long, _
    generatedRecordIsUsed() As Long _
)
    If translation.body.recordBindingCount <= 0 Then
        ReDim generatedRecordIsUsed(0 To 0)
        Exit Sub
    End If
    ReDim generatedRecordIsUsed( _
        0 To translation.body.recordBindingCount - 1)

    For bindingIndex As Long = 0 To translation.body.recordBindingCount - 1
        With translation.body.recordBindings(bindingIndex)
            If .isGenerated = 0 OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) Then Continue For
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) <> 0 AndAlso _
                   CBodyUsesIdentifier( _
                       candidates(candidateIndex).source, .fbName) <> 0 Then
                    generatedRecordIsUsed(bindingIndex) = -1
                    Exit For
                End If
            Next
            If generatedRecordIsUsed(bindingIndex) = 0 Then
                For objectIndex As Long = 0 To _
                    translation.body.externalObjectCount - 1
                    With translation.body.externalObjects(objectIndex)
                        If translation.body.includeGlobalDefinitions <> 0 AndAlso _
                           .isDefinition <> 0 AndAlso .isStatic = 0 Then
                            Dim objectCallbackIndex As Long = _
                                CBodyCallbackIndexInContext( _
                                    translation, .freeBasicType)
                            If objectCallbackIndex >= 0 AndAlso _
                               C2fbCallbackUsesRecordName( _
                                   translation, objectCallbackIndex, _
                                   translation.body.recordBindings( _
                                       bindingIndex).fbName) <> 0 Then
                                generatedRecordIsUsed(bindingIndex) = -1
                                Exit For
                            End If
                        End If
                        If .isAmbiguous <> 0 OrElse .isReused <> 0 OrElse _
                           (translation.body.includeGlobalDefinitions <> 0 AndAlso _
                            .isDefinition = 0) OrElse _
                           C2fbCTextContainsIdentifier( _
                               .freeBasicType, _
                               translation.body.recordBindings( _
                                   bindingIndex).fbName) = 0 Then Continue For
                        If translation.body.includeGlobalDefinitions <> 0 AndAlso _
                           .isDefinition <> 0 AndAlso .isStatic = 0 AndAlso _
                           InStr(.freeBasicType, " Ptr") = 0 Then
                            generatedRecordIsUsed(bindingIndex) = -1
                            Exit For
                        End If
                        For candidateIndex As Long = 0 To candidateCount - 1
                            If C2fbBodyCandidateWillBeEmitted( _
                                candidates(candidateIndex)) <> 0 AndAlso _
                               CBodyUsesIdentifier( _
                                   candidates(candidateIndex).source, _
                                   .freeBasicName) <> 0 Then
                                generatedRecordIsUsed(bindingIndex) = -1
                                Exit For
                            End If
                        Next
                    End With
                    If generatedRecordIsUsed(bindingIndex) <> 0 Then Exit For
                Next
            End If
        End With
    Next

    ' Source records are declared after the records they contain by value.
    ' Walk backward so a used parent also retains each generated field type.
    For ownerIndex As Long = translation.body.recordBindingCount - 1 To 0 Step -1
        If generatedRecordIsUsed(ownerIndex) = 0 OrElse _
           translation.body.recordBindings(ownerIndex).isGenerated = 0 OrElse _
           (translation.body.recordBindings(ownerIndex).recordKind <> _
                C2FB_RECORD_STRUCT AndAlso _
            translation.body.recordBindings(ownerIndex).recordKind <> _
                C2FB_RECORD_UNION) Then Continue For
        Dim ownerName As String = _
            translation.body.recordBindings(ownerIndex).fbName
        For fieldIndex As Long = 0 To catalog.bodyFieldCount - 1
            If catalog.bodyFields(fieldIndex).ownerName <> ownerName Then Continue For
            For nestedIndex As Long = 0 To _
                translation.body.recordBindingCount - 1
                With translation.body.recordBindings(nestedIndex)
                    If .isGenerated = 0 OrElse _
                       (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                        .recordKind <> C2FB_RECORD_UNION) OrElse _
                       C2fbCTextContainsIdentifier( _
                           catalog.bodyFields(fieldIndex).typeName, .fbName) = 0 Then _
                        Continue For
                    If generatedRecordIsUsed(nestedIndex) = 0 Then _
                        generatedRecordIsUsed(nestedIndex) = -1
                End With
            Next
        Next
    Next
End Sub

Private Sub WriteCBodyGeneratedLocalRecordTypes( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    generatedRecordIsUsed() As Long _
)
    If translation.body.recordBindingCount <= 0 Then Exit Sub
    For bindingIndex As Long = 0 To translation.body.recordBindingCount - 1
        With translation.body.recordBindings(bindingIndex)
            If generatedRecordIsUsed(bindingIndex) = 0 OrElse _
               .isGenerated = 0 OrElse _
               (.recordKind <> C2FB_RECORD_STRUCT AndAlso _
                .recordKind <> C2FB_RECORD_UNION) Then Continue For
            Dim localRecordKeyword As String = "Type"
            If .recordKind = C2FB_RECORD_UNION Then _
                localRecordKeyword = "Union"
            WriteC2fbOutputLine( _
                outputFile, "Private " & localRecordKeyword & " " & .fbName)
            If .recordKind = C2FB_RECORD_UNION Then
                Dim firstFieldIndex As Long = -1
                For candidateFieldIndex As Long = 0 To _
                    translation.body.recordFieldCount - 1
                    If translation.body.recordFields(candidateFieldIndex).ownerName = _
                       .sourceName Then
                        firstFieldIndex = candidateFieldIndex
                        Exit For
                    End If
                Next
                If firstFieldIndex >= 0 Then
                    With translation.body.recordFields(firstFieldIndex)
                        Dim arrayElementCount As Long = 0
                        If .isArray <> 0 AndAlso .isFlexibleArray = 0 AndAlso _
                           .pointerCount = 0 AndAlso .bitWidth < 0 AndAlso _
                           EvaluateSimpleArrayBound( _
                               .arrayBound, arrayElementCount, _
                               MAX_C2FB_UNION_ARRAY_INITIALIZER_ELEMENTS) <> 0 Then
                            Dim arrayElementType As String = CBodyFieldType( _
                                translation, catalog, firstFieldIndex, 0)
                            Dim arrayElementRecord As String = _
                                CBodyRecordName( _
                                    translation, catalog, arrayElementType)
                            If arrayElementCount > 0 AndAlso _
                               (SimpleArithmeticKind( _
                                    catalog, arrayElementType) <> 0 OrElse _
                                arrayElementRecord <> "" OrElse _
                                InStr(arrayElementType, " Ptr") <> 0 OrElse _
                                IsCBodyCallbackTypeInContext( _
                                    translation, arrayElementType) <> 0) Then
                                WriteC2fbOutputLine(outputFile, "    Type")
                                For elementIndex As Long = 0 To _
                                    arrayElementCount - 1
                                    Dim elementName As String = _
                                        "c2fb_array_initializer_element_" & _
                                        Trim(Str(elementIndex))
                                    Dim nameConflict As Long = -1
                                    While nameConflict <> 0
                                        nameConflict = 0
                                        For existingFieldIndex As Long = 0 To _
                                            translation.body.recordFieldCount - 1
                                            With translation.body.recordFields( _
                                                existingFieldIndex)
                                                If .ownerName <> translation.body.recordBindings( _
                                                    bindingIndex).sourceName Then _
                                                    Continue For
                                                If LCase(.name) = LCase(elementName) OrElse _
                                                   LCase(.freeBasicName) = LCase(elementName) Then
                                                    nameConflict = -1
                                                    Exit For
                                                End If
                                            End With
                                        Next
                                        If nameConflict <> 0 Then elementName &= "_"
                                    Wend
                                    WriteC2fbOutputLine( _
                                        outputFile, "        " & elementName & _
                                        " As " & arrayElementType)
                                Next
                                WriteC2fbOutputLine(outputFile, "    End Type")
                            End If
                        End If
                    End With
                End If
            End If
            For fieldIndex As Long = 0 To translation.body.recordFieldCount - 1
                With translation.body.recordFields(fieldIndex)
                    If .ownerName <> translation.body.recordBindings( _
                        bindingIndex).sourceName Then Continue For
                    Dim fbFieldIndex As Long = LookupFbBodyField( _
                        translation, catalog, _
                        translation.body.recordBindings(bindingIndex).fbName, _
                        .name, fieldIndex)
                    If fbFieldIndex < 0 Then _
                        ReportError("generated local record is missing field " & .name)
                    Dim fieldDeclaration As String = "    " & _
                        catalog.bodyFields(fbFieldIndex).name
                    If .isFlexibleArray <> 0 Then
                        WriteC2fbOutputLine( _
                            outputFile, _
                            "    ' C flexible array member size is expanded by --array-size: " & _
                            .name & "=" & .arrayBound)
                    End If
                    If catalog.bodyFields(fbFieldIndex).isArray <> 0 Then
                        Dim freeBasicArrayCountExpression As String = _
                            catalog.bodyFields( _
                                fbFieldIndex).freeBasicArrayCountExpression
                        If freeBasicArrayCountExpression <> "" Then
                            ' Let FBC size an imported header type in its target ABI.
                            fieldDeclaration &= "(0 To (" & _
                                freeBasicArrayCountExpression & ") - 1)"
                        Else
                            Dim arrayCount As Long
                            If EvaluateCBodyFixedArrayBound( _
                                translation, .arrayBound, arrayCount) = 0 OrElse _
                               arrayCount < 1 Then _
                                ReportError( _
                                    "generated local record has an invalid array bound")
                            fieldDeclaration &= "(0 To " & _
                                Trim(Str(arrayCount - 1)) & ")"
                        End If
                    End If
                    fieldDeclaration &= " As " & _
                        catalog.bodyFields(fbFieldIndex).typeName
                    WriteC2fbOutputLine(outputFile, fieldDeclaration)
                End With
            Next
            WriteC2fbOutputLine( _
                outputFile, "End " & localRecordKeyword)
            WriteC2fbOutputLine(outputFile, "")
        End With
    Next
End Sub

Private Function NormalizeC2fbBodyIncludedHeaderPath( _
    ByVal sourcePath As String _
) As String
    If sourcePath = "" OrElse Len(sourcePath) > 4096 Then Return ""
    Dim normalizedInput As String
    For position As Long = 1 To Len(sourcePath)
        If Asc(sourcePath, position) = 92 Then
            normalizedInput &= "/"
        Else
            normalizedInput &= Mid(sourcePath, position, 1)
        End If
    Next
    sourcePath = normalizedInput
    If Left(sourcePath, 1) = "/" OrElse InStr(sourcePath, ":") <> 0 Then _
        Return ""

    Dim components(0 To 255) As String
    Dim componentCount As Long = 0
    Dim componentStart As Long = 1
    For position As Long = 1 To Len(sourcePath) + 1
        If position <= Len(sourcePath) AndAlso _
           Mid(sourcePath, position, 1) <> "/" Then Continue For
        Dim component As String = Mid( _
            sourcePath, componentStart, position - componentStart)
        componentStart = position + 1
        If component = "" OrElse component = "." Then Continue For
        If component = ".." Then
            If componentCount = 0 Then Return ""
            componentCount -= 1
            Continue For
        End If
        If componentCount > UBound(components) Then Return ""
        components(componentCount) = component
        componentCount += 1
    Next

    Dim normalizedPath As String
    For componentIndex As Long = 0 To componentCount - 1
        If normalizedPath <> "" Then normalizedPath &= "/"
        normalizedPath &= components(componentIndex)
    Next
    Return normalizedPath
End Function

Private Function FbBodyIncludedHeaderName( _
    ByVal sourceLine As String _
) As String
    Dim lineText As String = LTrim(sourceLine)
    If Left(lineText, 1) <> "#" Then Return ""

    Dim position As Long = 2
    While position <= Len(lineText) AndAlso _
          IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    Dim directive As String
    While position <= Len(lineText) AndAlso _
          IsIdentifierPart(Asc(lineText, position)) <> 0
        directive &= Mid(lineText, position, 1)
        position += 1
    Wend
    If LCase(directive) <> "include" Then Return ""

    While position <= Len(lineText) AndAlso _
          IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    Dim includeWord As String
    Dim wordStart As Long = position
    While position <= Len(lineText) AndAlso _
          IsIdentifierPart(Asc(lineText, position)) <> 0
        includeWord &= Mid(lineText, position, 1)
        position += 1
    Wend
    If LCase(includeWord) = "once" Then
        While position <= Len(lineText) AndAlso _
              IsSpaceByte(Asc(lineText, position)) <> 0
            position += 1
        Wend
    Else
        position = wordStart
    End If
    If position > Len(lineText) OrElse _
       Mid(lineText, position, 1) <> Chr(34) Then Return ""

    Dim closingQuote As Long = InStr(position + 1, lineText, Chr(34))
    If closingQuote <= position + 1 Then Return ""
    Dim includedPath As String = Mid( _
        lineText, position + 1, closingQuote - position - 1)
    If LCase(Right(includedPath, 3)) <> ".bi" Then Return ""
    Return includedPath
End Function

Private Function ResolveC2fbBodyIncludedHeaderPath( _
    ByVal sourceDirectory As String, ByVal includingPath As String, _
    ByVal includedPath As String _
) As String
    Dim normalizedInclude As String = _
        NormalizeC2fbBodyIncludedHeaderPath(includedPath)
    If normalizedInclude = "" Then Return ""

    Dim separatorPosition As Long = InStrRev(includingPath, "/")
    If separatorPosition > 0 Then
        Dim relativeToIncludingFile As String = _
            NormalizeC2fbBodyIncludedHeaderPath( _
                Left(includingPath, separatorPosition) & includedPath)
        If relativeToIncludingFile <> "" AndAlso _
           FileLengthIfPresent( _
               sourceDirectory & "/" & relativeToIncludingFile) >= 0 Then _
            Return relativeToIncludingFile
    End If

    If FileLengthIfPresent( _
        sourceDirectory & "/" & normalizedInclude) >= 0 Then _
        Return normalizedInclude
    Return ""
End Function

Private Sub IndexC2fbCandidateIncludedDeclarations( _
    ByRef preamble As C2fbGeneratedFilePreambleModel, _
    ByVal sourceDirectory As String, _
    ByRef declarationNames As C2fbNameSetModel _
)
    ResetC2fbNameSet(declarationNames)
    If sourceDirectory = "" Then Exit Sub

    ' Follow local interface includes so declarations already visible through
    ' an included .bi do not get emitted a second time in the candidate file.
    Dim includedHeaders As C2fbSourceFileSetModel
    For entryIndex As Long = 0 To preamble.entryCount - 1
        With preamble.entries(entryIndex)
            If .kind <> C2FB_FILE_PREAMBLE_INCLUDE_ONCE Then Continue For
            If LCase(Right(.value, 3)) <> ".bi" Then Continue For
            Dim headerPath As String = _
                NormalizeC2fbBodyIncludedHeaderPath(.value)
            If headerPath = "" OrElse FileLengthIfPresent( _
                sourceDirectory & "/" & headerPath) < 0 Then
                headerPath = NormalizeC2fbBodyIncludedHeaderPath( _
                    FileNameOnly(.value))
            End If
            If headerPath = "" OrElse FileLengthIfPresent( _
                sourceDirectory & "/" & headerPath) < 0 Then Continue For
            If AppendC2fbSourceFileName( _
                includedHeaders, headerPath, -1) = 0 Then _
                ReportError("included body declaration closure exceeds its configured limit")
        End With
    Next

    Dim includedHeaderIndex As Long = 0
    While includedHeaderIndex < includedHeaders.itemCount
        Dim relativeHeaderPath As String = _
            includedHeaders.names(includedHeaderIndex)
        includedHeaderIndex += 1
        Dim headerPath As String = _
            sourceDirectory & "/" & relativeHeaderPath
        Dim lineReader As C2fbTextFileLineReaderModel
        If OpenC2fbTextFileLineReader(lineReader, headerPath) = 0 Then _
            ReportError("cannot read included body declaration file: " & headerPath)
        Dim sourceLine As String
        While ReadC2fbTextFileLine(lineReader, sourceLine) <> 0
            Dim declarationName As String = FbDeclarationName(sourceLine)
            If declarationName <> "" AndAlso _
               C2fbNameSetContains(declarationNames, declarationName) = 0 Then
                If AddC2fbNameSet(declarationNames, declarationName) = 0 Then _
                    ReportError("included body declaration index exceeds its configured limit")
            End If
            Dim declarationAlias As String = FbDeclarationAliasName(sourceLine)
            If declarationAlias <> "" AndAlso _
               C2fbNameSetContains(declarationNames, declarationAlias) = 0 Then
                If AddC2fbNameSet(declarationNames, declarationAlias) = 0 Then _
                    ReportError("included body declaration index exceeds its configured limit")
            End If

            Dim includedPath As String = _
                FbBodyIncludedHeaderName(sourceLine)
            If includedPath <> "" Then
                Dim resolvedPath As String = _
                    ResolveC2fbBodyIncludedHeaderPath( _
                        sourceDirectory, relativeHeaderPath, includedPath)
                If resolvedPath <> "" AndAlso _
                   AppendC2fbSourceFileName( _
                       includedHeaders, resolvedPath, -1) = 0 Then _
                    ReportError("included body declaration closure exceeds its configured limit")
            End If
        Wend
        CloseC2fbTextFileLineReader(lineReader)
    Wend
End Sub

Private Sub WriteCandidateDeclarations( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByVal sourceDirectory As String, _
    candidates() As C2fbBodyCandidateModel, _
    ByVal candidateCount As Long, _
    ByRef includedDeclarationNames As C2fbNameSetModel _
)
    Dim declarationFiles(0 To 1) As String
    declarationFiles(0) = "sqlite3_api_declarations.bi"
    declarationFiles(1) = "sqlite3_internal_api_declarations.bi"
    Dim emittedNames() As String
    ReDim emittedNames(0 To 255)
    Dim emittedCount As Long = 0

    For fileIndex As Long = 0 To UBound(declarationFiles)
        Dim declarationPath As String = _
            sourceDirectory & "/" & declarationFiles(fileIndex)
        Dim lineReader As C2fbTextFileLineReaderModel
        If OpenC2fbTextFileLineReader(lineReader, declarationPath) = 0 Then _
            ReportError("cannot read body declaration file: " & declarationPath)
        Dim sourceLine As String
        While ReadC2fbTextFileLine(lineReader, sourceLine) <> 0
            Dim procedureName As String = FbDeclarationName(sourceLine)
            Dim declarationAlias As String = FbDeclarationAliasName(sourceLine)
            Dim hasCandidateBody As Long = 0
            Dim isReferenced As Long = 0
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                   candidates(candidateIndex)) <> 0 AndAlso _
                   (candidates(candidateIndex).name = procedureName OrElse _
                    (declarationAlias <> "" AndAlso _
                     candidates(candidateIndex).name = declarationAlias)) AndAlso _
                   candidates(candidateIndex).duplicate = 0 Then
                    hasCandidateBody = -1
                End If
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) <> 0 AndAlso _
                   (CBodyUsesProcedure( _
                        candidates(candidateIndex).source, procedureName) <> 0 OrElse _
                    (declarationAlias <> "" AndAlso _
                     CBodyUsesProcedure( _
                        candidates(candidateIndex).source, declarationAlias) <> 0)) Then
                    isReferenced = -1
                End If
                If hasCandidateBody <> 0 AndAlso isReferenced <> 0 Then Exit For
            Next
            If Len(procedureName) <> 0 AndAlso _
               hasCandidateBody = 0 AndAlso _
               isReferenced <> 0 AndAlso _
               C2fbNameSetContains( _
                   includedDeclarationNames, procedureName) = 0 AndAlso _
               (declarationAlias = "" OrElse _
                C2fbNameSetContains( _
                    includedDeclarationNames, declarationAlias) = 0) AndAlso _
               C2fbNameListContains(emittedNames(), emittedCount, procedureName) = 0 Then
                WriteC2fbOutputLine(outputFile, sourceLine)
                If AddC2fbNameSet( _
                    includedDeclarationNames, procedureName) = 0 Then _
                    ReportError("candidate declaration index exceeds its configured limit")
                If declarationAlias <> "" AndAlso AddC2fbNameSet( _
                    includedDeclarationNames, declarationAlias) = 0 Then _
                    ReportError("candidate declaration index exceeds its configured limit")
                If emittedCount >= UBound(emittedNames) Then _
                    ReDim Preserve emittedNames(0 To UBound(emittedNames) * 2 + 1)
                emittedNames(emittedCount) = procedureName
                emittedCount += 1
            End If
        Wend
        CloseC2fbTextFileLineReader(lineReader)
    Next
End Sub

Private Sub WriteExistingBodyDeclarations( _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef includedDeclarationNames As C2fbNameSetModel, _
    candidates() As C2fbBodyCandidateModel, _
    ByVal candidateCount As Long _
)
    Dim candidateDefinitionNames As C2fbNameSetModel
    ResetC2fbNameSet(candidateDefinitionNames)
    For candidateIndex As Long = 0 To candidateCount - 1
        If C2fbBodyCandidateWillBeEmitted( _
            candidates(candidateIndex)) = 0 Then Continue For
        If AddC2fbNameSet( _
            candidateDefinitionNames, candidates(candidateIndex).name) = 0 Then _
            ReportError("candidate definition index exceeds its configured limit")
        If candidates(candidateIndex).procedureBinding.freeBasicName <> "" AndAlso _
           AddC2fbNameSet( _
               candidateDefinitionNames, _
               candidates(candidateIndex).procedureBinding.freeBasicName) = 0 Then _
            ReportError("candidate definition index exceeds its configured limit")
    Next

    Dim emittedNames() As String
    ReDim emittedNames(0 To 255)
    Dim emittedCount As Long = 0
    For signatureIndex As Long = 0 To catalog.bodyCallSignatureCount - 1
        With catalog.bodyCallSignatures(signatureIndex)
            If .canDeclare = 0 OrElse .declaration = "" OrElse .parameterCount < 0 Then Continue For
            If C2fbNameSetContains( _
                   includedDeclarationNames, .fbName) <> 0 OrElse _
               C2fbNameSetContains( _
                   includedDeclarationNames, .name) <> 0 OrElse _
               C2fbNameSetContains( _
                   candidateDefinitionNames, .fbName) <> 0 OrElse _
               C2fbNameSetContains( _
                   candidateDefinitionNames, .name) <> 0 OrElse _
               C2fbNameListContains(emittedNames(), emittedCount, .fbName) <> 0 OrElse _
               C2fbNameListContains(emittedNames(), emittedCount, .name) <> 0 Then Continue For

            Dim isReferenced As Long = 0
            For candidateIndex As Long = 0 To candidateCount - 1
                If candidates(candidateIndex).source = "" OrElse _
                   candidates(candidateIndex).duplicate <> 0 OrElse _
                   candidates(candidateIndex).skipMessage <> "" Then Continue For
                If CBodyUsesProcedure(candidates(candidateIndex).source, .fbName) <> 0 OrElse _
                   CBodyUsesProcedure(candidates(candidateIndex).source, .name) <> 0 Then
                    isReferenced = -1
                    Exit For
                End If
            Next
            If isReferenced = 0 Then Continue For

            Dim declarationText As String = Trim(.declaration)
            Dim loweredDeclaration As String = LCase(declarationText)
            If Left(loweredDeclaration, 8) = "private " OrElse _
               Left(loweredDeclaration, 7) = "static " Then Continue For
            If Left(loweredDeclaration, 7) = "public " Then
                declarationText = LTrim(Mid(declarationText, 8))
            End If
            If LCase(Right(RTrim(declarationText), 7)) = " export" Then _
                declarationText = Left(RTrim(declarationText), Len(RTrim(declarationText)) - 7)
            If Left(LCase(declarationText), 8) = "declare " Then
                WriteC2fbOutputLine(outputFile, declarationText)
            Else
                WriteC2fbOutputLine(outputFile, "Declare " & declarationText)
            End If
            If (.fbName <> "" AndAlso _
                AddC2fbNameSet(includedDeclarationNames, .fbName) = 0) OrElse _
               (.name <> "" AndAlso _
                AddC2fbNameSet(includedDeclarationNames, .name) = 0) Then _
                ReportError("candidate declaration index exceeds its configured limit")

            If emittedCount > UBound(emittedNames) Then _
                ReDim Preserve emittedNames(0 To UBound(emittedNames) * 2 + 1)
            emittedNames(emittedCount) = .fbName
            emittedCount += 1
            If .name <> .fbName AndAlso _
               C2fbNameListContains(emittedNames(), emittedCount, .name) = 0 Then
                If emittedCount > UBound(emittedNames) Then _
                    ReDim Preserve emittedNames(0 To UBound(emittedNames) * 2 + 1)
                emittedNames(emittedCount) = .name
                emittedCount += 1
            End If
        End With
    Next
End Sub

Private Function IsFbBodyGlobalObjectDeclarationLine( _
    ByVal sourceLine As String _
) As Long
    Dim lineText As String = LCase(LTrim(sourceLine))
    If lineText = "" OrElse Left(lineText, 1) = "'" OrElse _
       Left(lineText, 2) = "/'" OrElse Left(lineText, 1) = "#" Then Return 0

    If Left(lineText, Len("private ")) = "private " Then
        lineText = LTrim(Mid(lineText, Len("private ") + 1))
    ElseIf Left(lineText, Len("public ")) = "public " Then
        lineText = LTrim(Mid(lineText, Len("public ") + 1))
    End If

    If Left(lineText, Len("extern ")) = "extern " OrElse _
       Left(lineText, Len("common ")) = "common " Then Return -1
    If Left(lineText, Len("dim ")) <> "dim " Then Return 0

    Dim position As Long = Len("dim ") + 1
    While position <= Len(lineText) AndAlso _
          IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    Dim declarationKind As String = ""
    While position <= Len(lineText) AndAlso _
          IsIdentifierPart(Asc(lineText, position)) <> 0
        declarationKind &= Mid(lineText, position, 1)
        position += 1
    Wend
    If declarationKind = "shared" Then Return -1
    Return 0
End Function

Private Function CBodyReusedObjectDeclaredOnLine( _
    ByRef translation As C2fbTranslationContext, _
    candidates() As C2fbBodyCandidateModel, _
    ByVal candidateCount As Long, _
    ByVal sourceLine As String _
) As Long
    If IsFbBodyGlobalObjectDeclarationLine(sourceLine) = 0 Then Return 0

    For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
        With translation.body.externalObjects(objectIndex)
            If .isReused = 0 OrElse .isAmbiguous <> 0 OrElse _
               CBodyUsesIdentifier(sourceLine, .freeBasicName) = 0 Then Continue For
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) = 0 Then Continue For
                If CBodyUsesIdentifier( _
                    candidates(candidateIndex).source, .freeBasicName) <> 0 Then _
                    Return -1
            Next
        End With
    Next
    Return 0
End Function

Private Function CBodyUsesCrtMemory( _
    ByRef translation As C2fbTranslationContext, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long _
) As Long
    ' Header-selected function bodies can contain ordinary C memory calls
    ' after filtering removed their declarations from the FreeBASIC context.
    For candidateIndex As Long = 0 To candidateCount - 1
        If C2fbBodyCandidateWillBeEmitted( _
            candidates(candidateIndex)) = 0 Then Continue For
        For procedureNameIndex As Long = 0 To 3
            Dim procedureName As String
            Select Case procedureNameIndex
            Case 0: procedureName = "memcmp"
            Case 1: procedureName = "memcpy"
            Case 2: procedureName = "memmove"
            Case 3: procedureName = "memset"
            End Select
            If CBodyProcedureIndex(translation, procedureName) < 0 AndAlso _
               CBodyUsesProcedure( _
                   candidates(candidateIndex).source, procedureName) <> 0 Then _
                Return -1
        Next
    Next

    For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
        With translation.body.externalObjects(objectIndex)
            If .initializerText = "" OrElse .isAmbiguous <> 0 OrElse _
               .isReused <> 0 Then Continue For
            Dim objectInitializerIsUsed As Long = 0
            If .isStatic <> 0 Then
                For candidateIndex As Long = 0 To candidateCount - 1
                    If C2fbBodyCandidateWillBeEmitted( _
                        candidates(candidateIndex)) <> 0 AndAlso _
                       CBodyUsesIdentifier( _
                           candidates(candidateIndex).source, _
                           .freeBasicName) <> 0 Then
                        objectInitializerIsUsed = -1
                        Exit For
                    End If
                Next
            ElseIf translation.body.includeGlobalDefinitions <> 0 AndAlso _
                   .isDefinition <> 0 Then
                objectInitializerIsUsed = -1
            End If
            If objectInitializerIsUsed = 0 Then Continue For
            For procedureNameIndex As Long = 0 To 3
                Dim procedureName As String
                Select Case procedureNameIndex
                Case 0: procedureName = "memcmp"
                Case 1: procedureName = "memcpy"
                Case 2: procedureName = "memmove"
                Case 3: procedureName = "memset"
                End Select
                If CBodyUsesProcedure( _
                    .initializerText, procedureName) <> 0 Then Return -1
            Next
        End With
    Next
    Return 0
End Function

Private Sub WriteCandidateIncludes( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal targetProfile As C2fbTargetProfile, _
    ByRef filePreamble As C2fbGeneratedFilePreambleModel, _
    ByVal sourceDirectory As String, _
    candidates() As C2fbBodyCandidateModel, _
    ByVal candidateCount As Long _
)
    Dim hasCandidateBody As Long = 0
    For candidateIndex As Long = 0 To candidateCount - 1
        If candidates(candidateIndex).source <> "" AndAlso _
           candidates(candidateIndex).duplicate = 0 AndAlso _
           candidates(candidateIndex).skipMessage = "" Then
            hasCandidateBody = -1
            Exit For
        End If
    Next
    If hasCandidateBody = 0 AndAlso _
       translation.body.includeGlobalDefinitions <> 0 Then
        For objectIndex As Long = 0 To _
            translation.body.externalObjectCount - 1
            With translation.body.externalObjects(objectIndex)
                If .isDefinition <> 0 AndAlso .isStatic = 0 AndAlso _
                   .isAmbiguous = 0 AndAlso .isReused = 0 AndAlso _
                   .initializerText <> "" Then
                    hasCandidateBody = -1
                    Exit For
                End If
            End With
        Next
    End If
    If hasCandidateBody = 0 Then Exit Sub
    Dim isSqliteTarget As Long = CInt(targetProfile = C2FB_TARGET_SQLITE)

    ' A typed .bi declaration suppresses its generated API prototype. Include
    ' the owning header when a candidate calls it, otherwise the declaration
    ' index would promise a symbol that is absent from the emitted module.
    Dim sourceFiles As C2fbSourceFileSetModel
    If sourceDirectory <> "" AndAlso _
       AppendC2fbSourceDirectoryFiles( _
           sourceFiles, sourceDirectory, ".bi", 0, -1, _
           catalog.sourceRecursive) = 0 Then _
        ReportError("FreeBASIC interface tree exceeds the configured file limit")
    Dim declaredProcedureNameMap As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(declaredProcedureNameMap)
    Dim declaredProcedureNameCount As Long = 0
    For sourceFileIndex As Long = 0 To sourceFiles.itemCount - 1
        Dim declarationReader As C2fbTextFileLineReaderModel
        Dim declarationPath As String = _
            sourceDirectory & "/" & sourceFiles.names(sourceFileIndex)
        If OpenC2fbTextFileLineReader( _
            declarationReader, declarationPath) = 0 Then _
            ReportError("cannot read FreeBASIC body header: " & declarationPath)
        Dim declarationLine As String
        While ReadC2fbTextFileLine(declarationReader, declarationLine) <> 0
            If FbBodyIsProcedureDeclaration(declarationLine) = 0 Then _
                Continue While
            AddFbBodyDeclaredProcedureName( _
                declaredProcedureNameMap, declaredProcedureNameCount, _
                FbDeclarationName(declarationLine))
            AddFbBodyDeclaredProcedureName( _
                declaredProcedureNameMap, declaredProcedureNameCount, _
                FbDeclarationAliasName(declarationLine))
        Wend
        CloseC2fbTextFileLineReader(declarationReader)
    Next
    Dim calledProcedureNameMap As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(calledProcedureNameMap)
    Dim calledProcedureNameCount As Long = 0
    Dim calledSignatureTypeNameMap As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(calledSignatureTypeNameMap)
    Dim calledSignatureTypeNameCount As Long = 0
    For candidateIndex As Long = 0 To candidateCount - 1
        If candidates(candidateIndex).duplicate <> 0 OrElse _
           candidates(candidateIndex).source = "" OrElse _
           candidates(candidateIndex).skipMessage <> "" Then Continue For
        AddFbBodyCalledProcedureNames( _
            calledProcedureNameMap, calledProcedureNameCount, _
            candidates(candidateIndex).source)
        For objectIndex As Long = 0 To _
            translation.body.externalObjectCount - 1
            With translation.body.externalObjects(objectIndex)
                If .isArray = 0 OrElse .isStatic = 0 OrElse _
                   .isAmbiguous <> 0 OrElse .isReused <> 0 OrElse _
                   .initializerText = "" OrElse _
                   CBodyUsesIdentifier( _
                       candidates(candidateIndex).source, .freeBasicName) = 0 Then _
                    Continue For
                ' Module-level callback initializers are emitted separately
                ' from the candidate body, but their ProcPtr targets still
                ' need the bindings that normally follow direct C calls.
                AddFbBodyCalledProcedureNames( _
                    calledProcedureNameMap, calledProcedureNameCount, _
                    .initializerText)
            End With
        Next
        Dim procedureIndex As Long = CBodyProcedureIndex( _
            translation, candidates(candidateIndex).name)
        If procedureIndex >= 0 Then
            With translation.symbolTable.symbols(procedureIndex).body
                AddFbBodySignatureTypeNames( _
                    calledSignatureTypeNameMap, calledSignatureTypeNameCount, _
                    .returnType & "|" & .parameterTypes)
            End With
        End If
    Next
    If translation.body.includeGlobalDefinitions <> 0 Then
        For objectIndex As Long = 0 To _
            translation.body.externalObjectCount - 1
            With translation.body.externalObjects(objectIndex)
                If .isDefinition = 0 OrElse .isStatic <> 0 OrElse _
                   .isAmbiguous <> 0 OrElse .isReused <> 0 OrElse _
                   .initializerText = "" Then Continue For
                AddFbBodyCalledProcedureNames( _
                    calledProcedureNameMap, calledProcedureNameCount, _
                    .initializerText)
            End With
        Next
    End If
    For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
        With translation.symbolTable.symbols(symbolIndex)
            If .body.isDeclared = 0 Then Continue For
            Dim callName As String = CBodyCallName( _
                translation, catalog, .sourceName)
            If C2fbStringIndexMapLookup( _
                calledProcedureNameMap, LCase(.sourceName)) < 0 AndAlso _
               C2fbStringIndexMapLookup( _
                calledProcedureNameMap, LCase(.freeBasicName)) < 0 AndAlso _
               (callName = "" OrElse C2fbStringIndexMapLookup( _
                calledProcedureNameMap, LCase(callName)) < 0) Then Continue For
            AddFbBodySignatureTypeNames( _
                calledSignatureTypeNameMap, calledSignatureTypeNameCount, _
                .body.returnType & "|" & .body.parameterTypes)
        End With
    Next
    Dim needsCrtMath As Long = 0
    For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
        With translation.symbolTable.symbols(symbolIndex)
            If .body.isDeclared = 0 OrElse .body.isRuntime = 0 OrElse _
               IsCBodyRuntimeMathProcedure(.sourceName) = 0 Then Continue For
            Dim callName As String = CBodyCallName( _
                translation, catalog, .sourceName)
            If C2fbStringIndexMapLookup( _
                calledProcedureNameMap, LCase(.sourceName)) < 0 AndAlso _
               C2fbStringIndexMapLookup( _
                calledProcedureNameMap, LCase(.freeBasicName)) < 0 AndAlso _
               (callName = "" OrElse C2fbStringIndexMapLookup( _
                calledProcedureNameMap, LCase(callName)) < 0) Then Continue For
            If C2fbStringIndexMapLookup( _
                declaredProcedureNameMap, LCase(.sourceName)) < 0 AndAlso _
               C2fbStringIndexMapLookup( _
                declaredProcedureNameMap, LCase(.freeBasicName)) < 0 AndAlso _
               (callName = "" OrElse C2fbStringIndexMapLookup( _
                declaredProcedureNameMap, LCase(callName)) < 0) Then
                needsCrtMath = -1
                Exit For
            End If
        End With
    Next
    If needsCrtMath <> 0 Then
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "crt/math.bi") = 0 Then _
            ReportError("body candidate include list exceeds its configured limit")
    End If
    Dim needsCtypeMap As Long = 0
    Dim needsSmallTypeSizes As Long = 0
    Dim needsStdTypeTable As Long = 0
    Dim needsFunctionTableData As Long = 0
    Dim needsExtensionApiTable As Long = 0
    Dim needsProcessGlobals As Long = 0
    Dim needsPragmaColumnNames As Long = 0
    Dim needsMemsys3Types As Long = 0
    Dim macroNames(0 To 31) As String
    Dim macroCount As Long = 0
    For candidateIndex As Long = 0 To candidateCount - 1
        If isSqliteTarget <> 0 AndAlso _
           candidates(candidateIndex).duplicate = 0 AndAlso _
           candidates(candidateIndex).skipMessage = "" AndAlso _
           (InStr(candidates(candidateIndex).source, "sqlite3CtypeMap") <> 0 OrElse _
            InStr(candidates(candidateIndex).source, "sqlite3UpperToLower") <> 0) Then
            needsCtypeMap = -1
            Exit For
        End If
    Next
    For candidateIndex As Long = 0 To candidateCount - 1
        If isSqliteTarget <> 0 AndAlso _
           candidates(candidateIndex).duplicate = 0 AndAlso _
           candidates(candidateIndex).skipMessage = "" AndAlso _
           InStr(candidates(candidateIndex).source, "sqlite3SmallTypeSizes") <> 0 Then
            needsSmallTypeSizes = -1
            Exit For
        End If
    Next
    For candidateIndex As Long = 0 To candidateCount - 1
        If isSqliteTarget <> 0 AndAlso _
           candidates(candidateIndex).duplicate = 0 AndAlso _
           candidates(candidateIndex).skipMessage = "" AndAlso _
           InStr(candidates(candidateIndex).source, "sqlite3StdType") <> 0 Then
            needsStdTypeTable = -1
            Exit For
        End If
    Next
    For candidateIndex As Long = 0 To candidateCount - 1
        If isSqliteTarget <> 0 AndAlso _
           candidates(candidateIndex).duplicate = 0 AndAlso _
           candidates(candidateIndex).skipMessage = "" AndAlso _
           (InStr(candidates(candidateIndex).source, "globInfo") <> 0 OrElse _
            InStr(candidates(candidateIndex).source, "likeInfoNorm") <> 0 OrElse _
            InStr(candidates(candidateIndex).source, "likeInfoAlt") <> 0) Then
            needsFunctionTableData = -1
            Exit For
        End If
    Next
    For candidateIndex As Long = 0 To candidateCount - 1
        If isSqliteTarget <> 0 AndAlso _
           candidates(candidateIndex).duplicate = 0 AndAlso _
           candidates(candidateIndex).skipMessage = "" AndAlso _
           InStr(candidates(candidateIndex).source, "sqlite3Apis") <> 0 Then
            needsExtensionApiTable = -1
            Exit For
        End If
    Next
    For candidateIndex As Long = 0 To candidateCount - 1
        If isSqliteTarget <> 0 AndAlso _
           candidates(candidateIndex).duplicate = 0 AndAlso _
           candidates(candidateIndex).skipMessage = "" AndAlso _
           (InStr(candidates(candidateIndex).source, "sqlite3_temp_directory") <> 0 OrElse _
            InStr(candidates(candidateIndex).source, "sqlite3_data_directory") <> 0) Then
            needsProcessGlobals = -1
            Exit For
        End If
    Next
    For candidateIndex As Long = 0 To candidateCount - 1
        If isSqliteTarget <> 0 AndAlso _
           candidates(candidateIndex).duplicate = 0 AndAlso _
           candidates(candidateIndex).skipMessage = "" AndAlso _
           InStr(candidates(candidateIndex).source, "pragCName") <> 0 Then
            needsPragmaColumnNames = -1
            Exit For
        End If
    Next
    For candidateIndex As Long = 0 To candidateCount - 1
        If isSqliteTarget <> 0 AndAlso _
           candidates(candidateIndex).duplicate = 0 AndAlso _
           candidates(candidateIndex).skipMessage = "" AndAlso _
           InStr(candidates(candidateIndex).source, "mem3.") <> 0 Then
            needsMemsys3Types = -1
            Exit For
        End If
    Next
    For sourceFileIndex As Long = 0 To sourceFiles.itemCount - 1
        Dim fileName As String = sourceFiles.names(sourceFileIndex)
        If fileName <> "sqlite3_api_declarations.bi" AndAlso _
           fileName <> "sqlite3_internal_api_declarations.bi" AndAlso _
           (isSqliteTarget = 0 OrElse _
            (fileName <> "sqlite3_memsys3_types.bi" OrElse _
             needsMemsys3Types <> 0) AndAlso _
            (fileName <> "sqlite3_extension_api_table.bi" OrElse _
             needsExtensionApiTable <> 0) AndAlso _
            (fileName <> "sqlite3_process_globals.bi" OrElse _
             needsProcessGlobals <> 0)) Then
            Dim headerPath As String = sourceDirectory & "/" & fileName
            Dim lineReader As C2fbTextFileLineReaderModel
            If OpenC2fbTextFileLineReader(lineReader, headerPath) = 0 Then _
                ReportError("cannot read FreeBASIC body header: " & headerPath)
            Dim sourceLine As String
            Dim isNeeded As Long = 0
            Dim fileMacros(0 To 31) As String
            Dim fileMacroCount As Long = 0
            Dim pendingGlobalObjectDeclaration As String
            Dim headerProviderCache As C2fbStringIndexMapModel
            ResetC2fbStringIndexMap(headerProviderCache)
            isNeeded = NeedsFbBodyHeader( _
                translation, catalog, fileName, candidates(), candidateCount, _
                headerProviderCache)
            If isSqliteTarget <> 0 AndAlso _
               fileName = "sqlite3_memsys3_types.bi" AndAlso _
               needsMemsys3Types <> 0 Then isNeeded = -1
            If isSqliteTarget <> 0 AndAlso _
               fileName = "sqlite3_vdbe_record.bi" AndAlso _
               needsSmallTypeSizes <> 0 Then isNeeded = -1
            If isSqliteTarget <> 0 AndAlso _
               fileName = "sqlite3_process_globals.bi" AndAlso _
               needsProcessGlobals <> 0 Then isNeeded = -1
            While ReadC2fbTextFileLine(lineReader, sourceLine) <> 0
                If isNeeded = 0 Then
                    Dim objectDeclarationLine As String = sourceLine
                    If pendingGlobalObjectDeclaration <> "" Then _
                        objectDeclarationLine = _
                            pendingGlobalObjectDeclaration & " " & Trim(sourceLine)
                    If IsFbBodyGlobalObjectDeclarationLine( _
                        objectDeclarationLine) <> 0 Then
                        Dim trimmedObjectDeclaration As String = _
                            RTrim(objectDeclarationLine)
                        If Right(trimmedObjectDeclaration, 1) = "_" Then
                            pendingGlobalObjectDeclaration = RTrim(Left( _
                                trimmedObjectDeclaration, _
                                Len(trimmedObjectDeclaration) - 1))
                        Else
                            pendingGlobalObjectDeclaration = ""
                            If CBodyReusedObjectDeclaredOnLine( _
                                translation, candidates(), candidateCount, _
                                objectDeclarationLine) <> 0 Then isNeeded = -1
                        End If
                    Else
                        pendingGlobalObjectDeclaration = ""
                    End If
                End If
                If isNeeded = 0 Then
                    Dim procedureName As String = FbDeclarationName(sourceLine)
                    If Len(procedureName) <> 0 Then
                        Dim procedureAlias As String = _
                            FbDeclarationAliasName(sourceLine)
                        Dim isProcedureDeclaration As Long = _
                            FbBodyIsProcedureDeclaration(sourceLine)
                        Dim hasSeparateDeclaration As Long = 0
                        If isProcedureDeclaration = 0 Then
                            hasSeparateDeclaration = CInt( _
                                C2fbStringIndexMapLookup( _
                                    declaredProcedureNameMap, _
                                    LCase(procedureName)) >= 0 OrElse _
                                (procedureAlias <> "" AndAlso _
                                 C2fbStringIndexMapLookup( _
                                    declaredProcedureNameMap, _
                                    LCase(procedureAlias)) >= 0))
                        End If
                        If C2fbStringIndexMapLookup( _
                            calledProcedureNameMap, LCase(procedureName)) >= 0 OrElse _
                           (procedureAlias <> "" AndAlso C2fbStringIndexMapLookup( _
                            calledProcedureNameMap, LCase(procedureAlias)) >= 0) Then
                            isNeeded = -1
                        End If
                        If isProcedureDeclaration <> 0 OrElse _
                           hasSeparateDeclaration = 0 Then
                            For candidateIndex As Long = 0 To candidateCount - 1
                                If candidates(candidateIndex).duplicate <> 0 OrElse _
                                   candidates(candidateIndex).skipMessage <> "" OrElse _
                                   candidates(candidateIndex).source = "" Then Continue For
                                If CBodyUsesProcedure( _
                                    candidates(candidateIndex).source, procedureName) <> 0 OrElse _
                                   (procedureAlias <> "" AndAlso CBodyUsesProcedure( _
                                    candidates(candidateIndex).source, procedureAlias) <> 0) Then
                                    isNeeded = -1
                                    Exit For
                                End If
                            Next
                        End If
                    End If
                End If
                If isNeeded = 0 Then
                    Dim typeName As String = FbBodyTypeDeclarationName(sourceLine)
                    If typeName <> "" AndAlso _
                       C2fbStringIndexMapLookup( _
                           calledSignatureTypeNameMap, LCase(typeName)) >= 0 AndAlso _
                       FbBodyHeaderHasPreferredTypeProvider( _
                           catalog, fileName, typeName, _
                           headerProviderCache) = 0 Then _
                        isNeeded = -1
                End If

                ' C names are case-sensitive, while FreeBASIC names are not.
                ' Record header macros so a C procedure with the same spelling
                ' can be declared after the colliding macro is undefined.
                Dim lineText As String = LTrim(sourceLine)
                If Left(lineText, 7) = "#define" AndAlso _
                   (Len(lineText) = 7 OrElse IsSpaceByte(Asc(lineText, 8)) <> 0) Then
                    Dim position As Long = 8
                    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
                        position += 1
                    Wend
                    Dim macroName As String = ""
                    While position <= Len(lineText) AndAlso IsIdentifierPart(Asc(lineText, position)) <> 0
                        macroName &= Mid(lineText, position, 1)
                        position += 1
                    Wend
                    If Len(macroName) <> 0 Then
                        Dim alreadyRecorded As Long = 0
                        For macroIndex As Long = 0 To fileMacroCount - 1
                            If UCase(fileMacros(macroIndex)) = UCase(macroName) Then
                                alreadyRecorded = -1
                                Exit For
                            End If
                        Next
                        If alreadyRecorded = 0 AndAlso fileMacroCount <= UBound(fileMacros) Then
                            fileMacros(fileMacroCount) = macroName
                            fileMacroCount += 1
                        End If
                    End If
                End If
            Wend
            CloseC2fbTextFileLineReader(lineReader)
            If isNeeded <> 0 Then
                If AddC2fbGeneratedFileIncludeOnce( _
                    filePreamble, fileName) = 0 Then _
                    ReportError("body candidate include list exceeds its configured limit")
                For macroIndex As Long = 0 To fileMacroCount - 1
                    For candidateIndex As Long = 0 To candidateCount - 1
                        If candidates(candidateIndex).duplicate <> 0 OrElse _
                           candidates(candidateIndex).skipMessage <> "" OrElse _
                           Len(candidates(candidateIndex).source) = 0 Then Continue For
                        If UCase(candidates(candidateIndex).name) <> UCase(fileMacros(macroIndex)) Then Continue For
                        Dim alreadyRecorded As Long = 0
                        For recordedIndex As Long = 0 To macroCount - 1
                            If UCase(macroNames(recordedIndex)) = UCase(fileMacros(macroIndex)) Then
                                alreadyRecorded = -1
                                Exit For
                            End If
                        Next
                        If alreadyRecorded = 0 AndAlso macroCount <= UBound(macroNames) Then
                            macroNames(macroCount) = fileMacros(macroIndex)
                            macroCount += 1
                        End If
                        Exit For
                    Next
                Next
            End If
        End If
    Next
    If needsCtypeMap <> 0 Then _
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_global_data.bi") = 0 Then _
            ReportError("body candidate include list exceeds its configured limit")
    If needsStdTypeTable <> 0 Then _
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_std_types.bi") = 0 Then _
            ReportError("body candidate include list exceeds its configured limit")
    If needsFunctionTableData <> 0 Then _
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_function_tables.bi") = 0 Then _
            ReportError("body candidate include list exceeds its configured limit")
    If needsPragmaColumnNames <> 0 Then _
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_pragma_types.bi") = 0 Then _
            ReportError("body candidate include list exceeds its configured limit")
    For macroIndex As Long = 0 To macroCount - 1
        If AddC2fbGeneratedFileUndefine( _
            filePreamble, macroNames(macroIndex)) = 0 Then _
            ReportError("body candidate preamble exceeds its configured limit")
    Next
End Sub

Private Function C2fbBodyUsesRuntimeMath( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    candidates() As C2fbBodyCandidateModel, _
    ByVal candidateCount As Long _
) As Long
    For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
        With translation.symbolTable.symbols(symbolIndex)
            If .body.isDeclared = 0 OrElse .body.isRuntime = 0 OrElse _
               IsCBodyRuntimeMathProcedure(.sourceName) = 0 Then Continue For
            Dim callName As String = CBodyCallName( _
                translation, catalog, .sourceName)
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) = 0 Then Continue For
                If CBodyUsesProcedure( _
                       candidates(candidateIndex).source, .sourceName) <> 0 OrElse _
                   CBodyUsesProcedure( _
                       candidates(candidateIndex).source, .freeBasicName) <> 0 OrElse _
                   (callName <> "" AndAlso CBodyUsesProcedure( _
                       candidates(candidateIndex).source, callName) <> 0) Then _
                    Return -1
            Next
        End With
    Next
    Return 0
End Function

Declare Function TranslateCBodyModuleStaticInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal freeBasicType As String, ByVal isArray As Long, _
    ByVal initializerText As String, ByRef translatedText As String _
) As Long

Private Sub WriteCBodyDeclarations( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long, _
    ByRef includedDeclarationNames As C2fbNameSetModel, _
    ByVal keepUnresolvedDependencies As Long _
)
    Dim singleUsed As Long = 0
    Dim doubleUsed As Long = 0
    Dim builtinExpectUsed As Long = 0
    Dim builtinExpectProbabilityUsed As Long = 0
    For i As Long = 0 To candidateCount - 1
        If C2fbBodyCandidateWillBeEmitted(candidates(i)) = 0 Then Continue For
        If InStr(candidates(i).source, "__c2fb_single_value(") <> 0 Then singleUsed = -1
        If InStr(candidates(i).source, "__c2fb_double_value(") <> 0 Then doubleUsed = -1
        If InStr(candidates(i).source, "__c2fb_builtin_expect(") <> 0 Then _
            builtinExpectUsed = -1
        If InStr(candidates(i).source, _
                 "__c2fb_builtin_expect_with_probability(") <> 0 Then _
            builtinExpectProbabilityUsed = -1
    Next
    If singleUsed <> 0 Then
        WriteC2fbOutputLine( _
            outputFile, "Private Function __c2fb_single_value(ByVal value As Single) As Single")
        WriteC2fbOutputLine(outputFile, "    Return value")
        WriteC2fbOutputLine(outputFile, "End Function")
    End If
    If doubleUsed <> 0 Then
        WriteC2fbOutputLine( _
            outputFile, "Private Function __c2fb_double_value(ByVal value As Double) As Double")
        WriteC2fbOutputLine(outputFile, "    Return value")
        WriteC2fbOutputLine(outputFile, "End Function")
    End If
    If builtinExpectUsed <> 0 Then
        WriteC2fbOutputLine(outputFile, _
            "Private Function __c2fb_builtin_expect(ByVal value As c2fb_c_long, ByVal expected As c2fb_c_long) As c2fb_c_long")
        WriteC2fbOutputLine(outputFile, "    Return value")
        WriteC2fbOutputLine(outputFile, "End Function")
    End If
    If builtinExpectProbabilityUsed <> 0 Then
        WriteC2fbOutputLine(outputFile, _
            "Private Function __c2fb_builtin_expect_with_probability(ByVal value As c2fb_c_long, ByVal expected As c2fb_c_long, ByVal probability As Double) As c2fb_c_long")
        WriteC2fbOutputLine(outputFile, "    Return value")
        WriteC2fbOutputLine(outputFile, "End Function")
    End If
    For i As Long = 0 To candidateCount - 1
        If candidates(i).duplicate <> 0 OrElse _
           (candidates(i).source <> "" AndAlso _
            candidates(i).skipMessage <> "") Then Continue For
        If C2fbNameSetContains( _
            includedDeclarationNames, candidates(i).name) <> 0 OrElse _
           (candidates(i).procedureBinding.freeBasicName <> "" AndAlso _
            C2fbNameSetContains( _
                includedDeclarationNames, _
                candidates(i).procedureBinding.freeBasicName) <> 0) Then Continue For
        If candidates(i).source = "" Then
            If keepUnresolvedDependencies = 0 OrElse _
               candidates(i).procedureBinding.freeBasicName = "" OrElse _
               candidates(i).procedureBinding.cName = "" OrElse _
               candidates(i).procedureBinding.returnType = "" Then Continue For
            Dim isReferenced As Long = 0
            For callerIndex As Long = 0 To candidateCount - 1
                If callerIndex = i OrElse _
                   C2fbBodyCandidateWillBeEmitted(candidates(callerIndex)) = 0 Then _
                    Continue For
                If CBodyUsesProcedure( _
                       candidates(callerIndex).source, candidates(i).name) <> 0 OrElse _
                   CBodyUsesProcedure( _
                       candidates(callerIndex).source, _
                       candidates(i).procedureBinding.freeBasicName) <> 0 Then
                    isReferenced = -1
                    Exit For
                End If
            Next
            If isReferenced = 0 Then Continue For
        End If
        ' Preserve source linkage for skipped helpers. A static C helper has
        ' no external alias for other translation units to bind against.
        Dim unresolvedBinding As C2fbProcedureBindingModel = _
            candidates(i).procedureBinding
        EmitProcedureBinding(outputFile, unresolvedBinding)
    Next
    For p As Long = 0 To translation.symbolTable.symbolCount - 1
        With translation.symbolTable.symbols(p)
            If .body.isDeclared = 0 Then Continue For
            If .body.isRuntime = 0 Then Continue For
            Dim isUsed As Long = 0
            For i As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted(candidates(i)) = 0 Then Continue For
                If CBodyUsesProcedure( _
                    candidates(i).source, _
                    CBodySymbolFreeBasicName(translation, catalog, p)) <> 0 Then _
                    isUsed = -1
            Next
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) = 0 Then Continue For
                For objectIndex As Long = 0 To _
                    translation.body.externalObjectCount - 1
                    With translation.body.externalObjects(objectIndex)
                        If .initializerText = "" OrElse _
                           .isAmbiguous <> 0 OrElse .isReused <> 0 Then _
                            Continue For
                        Dim objectInitializerIsUsed As Long = 0
                        If .isStatic <> 0 Then
                            If CBodyUsesIdentifier( _
                                candidates(candidateIndex).source, _
                                .freeBasicName) <> 0 Then _
                                objectInitializerIsUsed = -1
                        ElseIf translation.body.includeGlobalDefinitions <> 0 AndAlso _
                               .isDefinition <> 0 Then
                            objectInitializerIsUsed = -1
                        End If
                        If objectInitializerIsUsed = 0 OrElse _
                           CBodyUsesIdentifier( _
                               .initializerText, _
                               CBodySymbolFreeBasicName( _
                                   translation, catalog, p)) = 0 Then Continue For
                        isUsed = -1
                        Exit For
                    End With
                Next
                If isUsed <> 0 Then Exit For
            Next
            If isUsed = 0 AndAlso _
               translation.body.includeGlobalDefinitions <> 0 Then
                ' A file-scope callback initializer is a use even when its C
                ' translation unit contains no function candidates.
                For objectIndex As Long = 0 To _
                    translation.body.externalObjectCount - 1
                    With translation.body.externalObjects(objectIndex)
                        If .initializerText = "" OrElse _
                           .isAmbiguous <> 0 OrElse .isReused <> 0 OrElse _
                           .isStatic <> 0 OrElse .isDefinition = 0 Then _
                            Continue For
                        If CBodyUsesIdentifier( _
                            .initializerText, CBodySymbolFreeBasicName( _
                                translation, catalog, p)) <> 0 Then
                            isUsed = -1
                            Exit For
                        End If
                    End With
                Next
            End If
            If isUsed = 0 Then Continue For
            Dim parameters As String
            For i As Long = 0 To .body.parameterCount - 1
                If i > 0 Then parameters &= ", "
                parameters &= "ByVal arg" & Trim(Str(i)) & " As " & _
                    CBodyParameterType(translation, catalog, .sourceName, i)
            Next
            If .body.isVariadic <> 0 Then parameters &= ", ..."
            Dim procedureBinding As C2fbProcedureBindingModel
            procedureBinding.freeBasicName = _
                CBodySymbolFreeBasicName(translation, catalog, p)
            procedureBinding.cName = .sourceName
            procedureBinding.linkName = .body.linkName
            procedureBinding.returnType = .body.returnType
            procedureBinding.parameterList = parameters
            procedureBinding.callingConvention = .body.callingConvention
            If procedureBinding.callingConvention = "" Then _
                procedureBinding.callingConvention = "CDecl"
            procedureBinding.isSub = CInt(.body.returnType = "void") * -1
            procedureBinding.isPrivate = CInt(.body.isStatic <> 0) * -1
            EmitProcedureBinding(outputFile, procedureBinding)
        End With
    Next

    For p As Long = 0 To translation.symbolTable.symbolCount - 1
        With translation.symbolTable.symbols(p)
            If .body.isExternal = 0 OrElse .body.isAmbiguous <> 0 OrElse _
               .ambiguous <> 0 Then Continue For
            Dim freeBasicName As String = _
                CBodySymbolFreeBasicName(translation, catalog, p)
            ' A selected inline body replaces the same C external symbol.
            Dim hasCandidateDefinition As Long = 0
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) = 0 Then Continue For
                If candidates(candidateIndex).name = .sourceName OrElse _
                   (candidates(candidateIndex).procedureBinding.freeBasicName <> "" AndAlso _
                    candidates(candidateIndex).procedureBinding.freeBasicName = freeBasicName) Then
                    hasCandidateDefinition = -1
                    Exit For
                End If
            Next
            If hasCandidateDefinition <> 0 Then Continue For
            If C2fbNameSetContains( _
                includedDeclarationNames, freeBasicName) <> 0 Then _
                Continue For
            Dim isUsed As Long = 0
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) = 0 Then Continue For
                If CBodyUsesProcedure( _
                    candidates(candidateIndex).source, freeBasicName) <> 0 Then
                    isUsed = -1
                    Exit For
                End If
            Next
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) = 0 Then Continue For
                For objectIndex As Long = 0 To _
                    translation.body.externalObjectCount - 1
                    With translation.body.externalObjects(objectIndex)
                        If .initializerText = "" OrElse _
                           .isAmbiguous <> 0 OrElse .isReused <> 0 Then _
                            Continue For
                        Dim objectInitializerIsUsed As Long = 0
                        If .isStatic <> 0 Then
                            If CBodyUsesIdentifier( _
                                candidates(candidateIndex).source, _
                                .freeBasicName) <> 0 Then _
                                objectInitializerIsUsed = -1
                        ElseIf translation.body.includeGlobalDefinitions <> 0 AndAlso _
                               .isDefinition <> 0 Then
                            objectInitializerIsUsed = -1
                        End If
                        If objectInitializerIsUsed = 0 OrElse _
                           CBodyUsesIdentifier( _
                               .initializerText, freeBasicName) = 0 Then Continue For
                        isUsed = -1
                        Exit For
                    End With
                Next
                If isUsed <> 0 Then Exit For
            Next
            If isUsed = 0 Then Continue For

            ' Existing FreeBASIC declarations may provide the same private
            ' helper signature used by this C source. Keep one prototype in
            ' the candidate module when both catalogs describe the call.
            Dim bodySignatureIndex As Long = _
                FbBodyCallSignatureIndex(catalog, .sourceName)
            If bodySignatureIndex >= 0 AndAlso _
               catalog.bodyCallSignatures(bodySignatureIndex).canDeclare <> 0 Then _
                Continue For

            Dim parameters As String
            Dim parameterListIsComplete As Long = -1
            For parameterIndex As Long = 0 To .body.parameterCount - 1
                Dim parameterType As String = CBodyParameterType( _
                    translation, catalog, .sourceName, parameterIndex)
                If parameterType = "" Then
                    parameterListIsComplete = 0
                    Exit For
                End If
                If parameterIndex > 0 Then parameters &= ", "
                parameters &= "ByVal arg" & Trim(Str(parameterIndex)) & _
                              " As " & parameterType
            Next
            If parameterListIsComplete = 0 Then Continue For
            If .body.isVariadic <> 0 Then
                If .body.parameterCount = 0 Then Continue For
                If parameters <> "" Then parameters &= ", "
                parameters &= "..."
            End If

            Dim procedureBinding As C2fbProcedureBindingModel
            procedureBinding.freeBasicName = freeBasicName
            procedureBinding.cName = .cName
            procedureBinding.linkName = .body.linkName
            procedureBinding.returnType = .body.returnType
            procedureBinding.parameterList = parameters
            procedureBinding.callingConvention = .body.callingConvention
            If procedureBinding.callingConvention = "" Then _
                procedureBinding.callingConvention = "CDecl"
            procedureBinding.isSub = CInt(.body.returnType = "void") * -1
            procedureBinding.isPrivate = CInt(.body.isStatic <> 0) * -1
            EmitProcedureBinding(outputFile, procedureBinding)
        End With
    Next

    If translation.body.generatedStaticDeclarations <> "" Then
        ' C file-scope compound literals require distinct storage before any
        ' global pointer initializer that refers to their address.
        WriteC2fbOutputLine( _
            outputFile, "' C backing storage for static char-array literals")
        WriteC2fbOutputText( _
            outputFile, translation.body.generatedStaticDeclarations)
        WriteC2fbOutputLine(outputFile, "")
    End If

    Dim externalObjectIsUsed(Any) As Long
    If translation.body.externalObjectCount > 0 Then
        ReDim externalObjectIsUsed( _
            0 To translation.body.externalObjectCount - 1)
    End If
    For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
        With translation.body.externalObjects(objectIndex)
            If .isAmbiguous <> 0 OrElse .isReused <> 0 Then Continue For
            externalObjectIsUsed(objectIndex) = CInt( _
                translation.body.includeGlobalDefinitions <> 0 AndAlso _
                .isDefinition <> 0 AndAlso .isStatic = 0) * -1
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) = 0 Then Continue For
                If CBodyUsesIdentifier( _
                    candidates(candidateIndex).source, .freeBasicName) <> 0 Then
                    externalObjectIsUsed(objectIndex) = -1
                    Exit For
                End If
            Next
        End With
    Next
    ' A private object can be needed only by another object's constant
    ' initializer. Include those dependencies before emitting storage.
    Dim dependencyAdded As Long
    Do
        dependencyAdded = 0
        For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
            If externalObjectIsUsed(objectIndex) = 0 Then Continue For
            With translation.body.externalObjects(objectIndex)
                If .initializerText = "" Then Continue For
                For dependencyIndex As Long = 0 To _
                    translation.body.externalObjectCount - 1
                    If externalObjectIsUsed(dependencyIndex) <> 0 Then Continue For
                    With translation.body.externalObjects(dependencyIndex)
                        If .isAmbiguous <> 0 OrElse .isReused <> 0 Then Continue For
                        Dim initializerUsesDependency As Long = _
                            CBodyUsesIdentifier( _
                                translation.body.externalObjects( _
                                    objectIndex).initializerText, .freeBasicName)
                        If initializerUsesDependency = 0 AndAlso .sourceName <> "" Then _
                            initializerUsesDependency = CBodyUsesIdentifier( _
                                translation.body.externalObjects( _
                                    objectIndex).initializerText, .sourceName)
                        If initializerUsesDependency = 0 Then Continue For
                        externalObjectIsUsed(dependencyIndex) = -1
                        dependencyAdded = -1
                    End With
                Next
            End With
        Next
        If dependencyAdded = 0 Then Exit Do
    Loop

    ' File-scope initializers can point at private arrays declared later in
    ' the C source. Emit those dependencies first because FreeBASIC requires
    ' a backing object to be declared before its address appears in a static
    ' initializer.
    Dim externalObjectEmissionOrder(Any) As Long
    Dim externalObjectWasEmitted(Any) As Long
    If translation.body.externalObjectCount > 0 Then
        ReDim externalObjectEmissionOrder( _
            0 To translation.body.externalObjectCount - 1)
        ReDim externalObjectWasEmitted( _
            0 To translation.body.externalObjectCount - 1)
    End If
    Dim externalObjectEmissionCount As Long = 0
    Do
        Dim emittedObjectThisPass As Long = 0
        For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
            If externalObjectIsUsed(objectIndex) = 0 OrElse _
               externalObjectWasEmitted(objectIndex) <> 0 Then Continue For
            With translation.body.externalObjects(objectIndex)
                If .isAmbiguous <> 0 OrElse .isReused <> 0 Then Continue For
                Dim dependenciesReady As Long = -1
                If .initializerText <> "" Then
                    For dependencyIndex As Long = 0 To _
                        translation.body.externalObjectCount - 1
                        If dependencyIndex = objectIndex OrElse _
                           externalObjectIsUsed(dependencyIndex) = 0 OrElse _
                           externalObjectWasEmitted(dependencyIndex) <> 0 Then _
                            Continue For
                        With translation.body.externalObjects(dependencyIndex)
                            If .isAmbiguous <> 0 OrElse .isReused <> 0 OrElse _
                               .freeBasicName = "" Then Continue For
                            Dim initializerUsesDependency As Long = _
                                CBodyUsesIdentifier( _
                                    translation.body.externalObjects( _
                                        objectIndex).initializerText, .freeBasicName)
                            If initializerUsesDependency = 0 AndAlso .sourceName <> "" Then _
                                initializerUsesDependency = CBodyUsesIdentifier( _
                                    translation.body.externalObjects( _
                                        objectIndex).initializerText, .sourceName)
                            If initializerUsesDependency <> 0 Then
                                dependenciesReady = 0
                                Exit For
                            End If
                        End With
                    Next
                End If
                If dependenciesReady = 0 Then Continue For
                externalObjectEmissionOrder(externalObjectEmissionCount) = objectIndex
                externalObjectEmissionCount += 1
                externalObjectWasEmitted(objectIndex) = -1
                emittedObjectThisPass = -1
            End With
        Next
        If emittedObjectThisPass = 0 Then Exit Do
    Loop

    ' Keep any cyclic constant-address initializers deterministic. C2FB does
    ' not synthesize mutable startup code for them, so the backend can report
    ' a forward declaration problem if FreeBASIC cannot resolve the cycle.
    For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
        If externalObjectIsUsed(objectIndex) = 0 OrElse _
           externalObjectWasEmitted(objectIndex) <> 0 Then Continue For
        With translation.body.externalObjects(objectIndex)
            If .isAmbiguous <> 0 OrElse .isReused <> 0 Then Continue For
        End With
        externalObjectEmissionOrder(externalObjectEmissionCount) = objectIndex
        externalObjectEmissionCount += 1
        externalObjectWasEmitted(objectIndex) = -1
    Next

    For emissionIndex As Long = 0 To externalObjectEmissionCount - 1
        Dim emissionObjectIndex As Long = _
            externalObjectEmissionOrder(emissionIndex)
        With translation.body.externalObjects(emissionObjectIndex)
            If .isAmbiguous <> 0 OrElse .isReused <> 0 Then Continue For
            Dim isGlobalDefinition As Long = CInt( _
                translation.body.includeGlobalDefinitions <> 0 AndAlso _
                .isDefinition <> 0 AndAlso .isStatic = 0) * -1
            Dim isUsed As Long = externalObjectIsUsed(emissionObjectIndex)
            If isUsed = 0 OrElse C2fbNameSetContains( _
                includedDeclarationNames, .freeBasicName) <> 0 Then _
                Continue For
            Dim arrayBounds As String
            If .isArray <> 0 AndAlso .isUnsizedArray = 0 Then
                If .arrayCount <= 0 Then Continue For
                arrayBounds = "(0 To " & Trim(Str(.arrayCount - 1)) & ")"
            End If
            If .isStatic <> 0 Then
                Dim storageDeclaration As String
                Dim isCallbackArray As Long = CInt( _
                    .isArray <> 0 AndAlso _
                    CBodyCallbackIndexInContext( _
                        translation, .freeBasicType) >= 0) * -1
                Dim isConstRecord As Long = 0
                If .isConst <> 0 AndAlso .isArray = 0 AndAlso _
                   InStr(.freeBasicType, " Ptr") = 0 AndAlso _
                   CBodyRecordName( _
                       translation, catalog, .freeBasicType) <> "" Then _
                    isConstRecord = -1
                If isCallbackArray <> 0 Then
                    ' FreeBASIC cannot qualify a procedure-pointer alias as Const.
                    ' C constness remains tracked when lowering writes to this object.
                    Dim arrayElementType As String = .freeBasicType
                    storageDeclaration = "Private Dim Shared " & .freeBasicName & _
                        arrayBounds & " As " & arrayElementType
                ElseIf .isConst <> 0 AndAlso isConstRecord = 0 Then
                    storageDeclaration = "Private Const " & .freeBasicName & arrayBounds & _
                        " As " & .freeBasicType
                Else
                    If isConstRecord <> 0 Then
                        ' FreeBASIC Const values cannot provide addressable UDT storage.
                        ' The body model still rejects writes to this C const object.
                        WriteC2fbOutputLine(outputFile, _
                            "' C const record uses private addressable storage.")
                    End If
                    storageDeclaration = "Private Dim Shared " & .freeBasicName & arrayBounds & _
                        " As " & .freeBasicType
                End If
                If .initializerText <> "" Then
                    Dim translatedInitializer As String
                    TranslateCBodyModuleStaticInitializer( _
                        translation, catalog, .freeBasicType, .isArray, _
                        .initializerText, translatedInitializer)
                    storageDeclaration &= " = " & translatedInitializer
                End If
                WriteC2fbOutputLine(outputFile, storageDeclaration)
                Continue For
            End If
            If isGlobalDefinition <> 0 Then
                Dim globalType As String = .freeBasicType
                If .isConst <> 0 AndAlso Left(globalType, 6) <> "Const " Then _
                    globalType = "Const " & globalType
                Dim globalStorageDeclaration As String = _
                    "Dim Shared " & .freeBasicName & arrayBounds & _
                    " Alias " & Chr(34) & .cName & Chr(34) & _
                    " As " & globalType
                If .initializerText <> "" Then
                    Dim translatedInitializer As String
                    TranslateCBodyModuleStaticInitializer( _
                        translation, catalog, .freeBasicType, .isArray, _
                        .initializerText, translatedInitializer)
                    globalStorageDeclaration &= " = " & translatedInitializer
                End If
                WriteC2fbOutputLine( _
                    outputFile, "' c2fb global definition " & .cName & "=" & _
                    .freeBasicName)
                WriteC2fbOutputLine(outputFile, globalStorageDeclaration)
                Continue For
            End If
            Dim objectBinding As C2fbObjectBindingModel
            objectBinding.freeBasicName = .freeBasicName
            objectBinding.cName = .cName
            objectBinding.freeBasicType = .freeBasicType
            objectBinding.arrayCount = .arrayCount
            objectBinding.isUnsizedArray = .isUnsizedArray
            objectBinding.storageName = .storageName
            WriteC2fbObjectBinding(outputFile, objectBinding)
        End With
    Next
End Sub

Private Function C2fbSourcePathCommentValue(ByVal sourcePath As String) As String
    Dim result As String
    For position As Long = 1 To Len(sourcePath)
        Dim currentByte As Long = Asc(sourcePath, position)
        If currentByte = Asc(Chr(10)) OrElse currentByte = Asc(Chr(13)) Then
            result &= " "
        Else
            result &= Chr(currentByte)
        End If
    Next
    Return result
End Function

Private Sub WriteC2fbBodyCandidateSource( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef candidate As C2fbBodyCandidateModel _
)
    Dim signatureEnd As Long = InStr(candidate.source, Chr(10))
    If signatureEnd = 0 Then
        WriteC2fbOutputText(outputFile, candidate.source)
        Exit Sub
    End If
    Dim signatureLine As String = Left(candidate.source, signatureEnd - 1)
    If Right(signatureLine, 1) = Chr(13) Then _
        signatureLine = Left(signatureLine, Len(signatureLine) - 1)
    WriteC2fbGeneratedFileLine(outputFile, signatureLine)
    If candidate.sourceLocation.path <> "" Then
        WriteC2fbGeneratedFileLine( _
            outputFile, "' c2fb source-path: " & _
            C2fbSourcePathCommentValue(candidate.sourceLocation.path))
        If candidate.sourceLocation.line > 0 Then _
            WriteC2fbGeneratedFileLine( _
                outputFile, "' c2fb source-line: " & _
                Trim(Str(candidate.sourceLocation.line)))
        If candidate.sourceLocation.column > 0 Then _
            WriteC2fbGeneratedFileLine( _
                outputFile, "' c2fb source-column: " & _
                Trim(Str(candidate.sourceLocation.column)))
    End If
    WriteC2fbOutputText(outputFile, Mid(candidate.source, signatureEnd + 1))
End Sub

Private Sub WriteC2fbHalfFloatConversionHelpers( _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    WriteC2fbGeneratedFileLine(outputFile, _
        "Private Function c2fb_float16_to_single(ByVal bits As c2fb_float16) As Single")
    WriteC2fbGeneratedFileLine(outputFile, _
        "    Dim signBits As ULong = CULng(bits And &H8000) Shl 16")
    WriteC2fbGeneratedFileLine(outputFile, _
        "    Dim exponent As Long = (bits Shr 10) And &H1F")
    WriteC2fbGeneratedFileLine(outputFile, _
        "    Dim fraction As ULong = CULng(bits And &H03FF)")
    WriteC2fbGeneratedFileLine(outputFile, "    Dim floatBits As ULong")
    WriteC2fbGeneratedFileLine(outputFile, "    If exponent = 0 Then")
    WriteC2fbGeneratedFileLine(outputFile, "        If fraction = 0 Then")
    WriteC2fbGeneratedFileLine(outputFile, "            floatBits = signBits")
    WriteC2fbGeneratedFileLine(outputFile, "        Else")
    WriteC2fbGeneratedFileLine(outputFile, _
        "            Dim significand As ULong = fraction")
    WriteC2fbGeneratedFileLine(outputFile, _
        "            Dim unbiasedExponent As Long = -14")
    WriteC2fbGeneratedFileLine(outputFile, "            While significand < 1024")
    WriteC2fbGeneratedFileLine(outputFile, _
        "                significand = significand Shl 1")
    WriteC2fbGeneratedFileLine(outputFile, "                unbiasedExponent -= 1")
    WriteC2fbGeneratedFileLine(outputFile, "            Wend")
    WriteC2fbGeneratedFileLine(outputFile, _
        "            floatBits = signBits Or " & _
        "(CULng(unbiasedExponent + 127) Shl 23) Or " & _
        "((significand And &H03FF) Shl 13)")
    WriteC2fbGeneratedFileLine(outputFile, "        End If")
    WriteC2fbGeneratedFileLine(outputFile, "    ElseIf exponent = 31 Then")
    WriteC2fbGeneratedFileLine(outputFile, _
        "        floatBits = signBits Or (CULng(&HFF) Shl 23) Or " & _
        "(fraction Shl 13)")
    WriteC2fbGeneratedFileLine(outputFile, "    Else")
    WriteC2fbGeneratedFileLine(outputFile, _
        "        floatBits = signBits Or (CULng(exponent + 112) Shl 23) Or " & _
        "(fraction Shl 13)")
    WriteC2fbGeneratedFileLine(outputFile, "    End If")
    WriteC2fbGeneratedFileLine(outputFile, "    Dim result As Single")
    WriteC2fbGeneratedFileLine(outputFile, _
        "    memcpy(@result, @floatBits, SizeOf(result))")
    WriteC2fbGeneratedFileLine(outputFile, "    Return result")
    WriteC2fbGeneratedFileLine(outputFile, "End Function")
    WriteC2fbGeneratedFileLine(outputFile, "")
    WriteC2fbGeneratedFileLine(outputFile, _
        "Private Function c2fb_bfloat16_to_single(ByVal bits As c2fb_bfloat16) As Single")
    WriteC2fbGeneratedFileLine(outputFile, _
        "    Dim floatBits As ULong = CULng(bits) Shl 16")
    WriteC2fbGeneratedFileLine(outputFile, "    Dim result As Single")
    WriteC2fbGeneratedFileLine(outputFile, _
        "    memcpy(@result, @floatBits, SizeOf(result))")
    WriteC2fbGeneratedFileLine(outputFile, "    Return result")
    WriteC2fbGeneratedFileLine(outputFile, "End Function")
    WriteC2fbGeneratedFileLine(outputFile, "")
End Sub

' Rejected expressions may include multiline C text; generated diagnostic comments stay on one line.
Private Function C2fbBodyDiagnosticCommentText( _
    ByVal diagnosticText As String _
) As String
    Dim result As String
    For position As Long = 1 To Len(diagnosticText)
        Dim currentByte As Long = Asc(diagnosticText, position)
        If currentByte < Asc(" ") Then
            If result <> "" AndAlso Right(result, 1) <> " " Then result &= " "
        Else
            result &= Chr(currentByte)
        End If
        If Len(result) >= MAX_C2FB_BODY_DIAGNOSTIC_COMMENT_LENGTH Then
            result = Left(result, MAX_C2FB_BODY_DIAGNOSTIC_COMMENT_LENGTH - 3) & "..."
            Exit For
        End If
    Next
    Return Trim(result)
End Function

Private Sub WriteC2fbBodyCandidateDiagnostic( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef diagnostic As C2fbDiagnosticModel _
)
    Dim locationText As String
    If diagnostic.location.line > 0 Then
        locationText = " line " & Trim(Str(diagnostic.location.line))
        If diagnostic.location.column > 0 Then _
            locationText &= ":" & Trim(Str(diagnostic.location.column))
    End If
    Dim diagnosticText As String = _
        C2fbBodyDiagnosticCommentText(diagnostic.message)
    WriteC2fbGeneratedFileLine( _
        outputFile, "' c2fb body diagnostic [" & diagnostic.code & "]" & _
        locationText & ": " & diagnosticText)
End Sub

Private Sub WriteC2fbBodyRenameReport( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If translation.genericC.policy.symbolRenameCount = 0 AndAlso _
       translation.genericC.policy.procedureNamePrefix = "" Then Exit Sub
    If translation.genericC.policy.symbolRenameCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "' c2fb body rename mappings:")
    For renameIndex As Long = 0 To _
        translation.genericC.policy.symbolRenameCount - 1
        With translation.genericC.policy.symbolRenames(renameIndex)
            Dim stateText As String = "unused"
            If .matched <> 0 Then stateText = "matched"
            Dim namespaceText As String
            Select Case .renameNamespace
            Case C2FB_SYMBOL_RENAME_TAG: namespaceText = "tag "
            Case C2FB_SYMBOL_RENAME_TYPEDEF: namespaceText = "typedef "
            Case C2FB_SYMBOL_RENAME_PROCEDURE: namespaceText = "procedure "
            Case C2FB_SYMBOL_RENAME_DEFINE: namespaceText = "macro "
            Case C2FB_SYMBOL_RENAME_MACRO_PARAMETER: namespaceText = "macro parameter "
            End Select
            WriteC2fbOutputLine(outputFile, "' c2fb " & namespaceText & _
                "rename " & stateText & ": " & .sourceName & " -> " & _
                .freeBasicName)
        End With
    Next
    If translation.genericC.policy.procedureNamePrefix <> "" Then
        Dim prefixState As String = "unused"
        If translation.genericC.policy.procedureNamePrefixMatched <> 0 Then _
            prefixState = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb body procedure rename prefix " & _
            prefixState & ": " & _
            translation.genericC.policy.procedureNamePrefix)
    End If
End Sub

Private Function TranslateCBodyModuleStaticInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal freeBasicType As String, ByVal isArray As Long, _
    ByVal initializerText As String, ByRef translatedText As String _
) As Long
    translatedText = initializerText
    initializerText = Trim(initializerText)
    If initializerText = "" Then Return -1

    If isArray <> 0 Then
        If Left(initializerText, 1) <> "{" Then Return -1
        Dim closingBrace As Long = 1
        If ScanSimpleExpressionGroup( _
            initializerText, closingBrace, Asc("{"), Asc("}")) = 0 OrElse _
           Trim(Mid(initializerText, closingBrace)) <> "" Then Return -1
        Dim initializerBody As String = Trim(Mid( _
            initializerText, 2, closingBrace - 3))
        If initializerBody = "" Then Return -1
        If Right(initializerBody, 1) = "," Then _
            initializerBody = RTrim(Left( _
                initializerBody, Len(initializerBody) - 1))

        Dim values() As String
        Dim valueCount As Long
        If SplitSimpleCList( _
            initializerBody, values(), valueCount, 0, _
            MAX_GENERIC_STATIC_INITIALIZER_VALUES) = 0 OrElse _
           valueCount <= 0 Then Return -1

        Dim context As SimpleBodyContext
        Dim callableNames(0 To 0) As String
        Dim parameterNames(0 To 0) As String
        Dim parameterAliases(0 To 0) As String
        Dim parameterTypes(0 To 0) As String
        Dim translatedValues As String
        For valueIndex As Long = 0 To valueCount - 1
            Dim sourceValue As String = Trim(values(valueIndex))
            Dim translatedValue As String = sourceValue
            If Left(sourceValue, 1) = "{" AndAlso _
               CBodyRecordName(translation, catalog, freeBasicType) <> "" Then
                If TranslateSimpleRecordInitializer( _
                    translation, catalog, sourceValue, freeBasicType, _
                    translatedValue, context, callableNames(), 0, _
                    parameterNames(), parameterAliases(), parameterTypes(), 0) = 0 Then _
                    Return -1
            Else
                Dim hasBooleanOperator As Long
                Dim hasFunctionCall As Long
                If TranslateSimpleExpression( _
                    translation, catalog, sourceValue, translatedValue, _
                    hasBooleanOperator, hasFunctionCall, callableNames(), 0, _
                    parameterNames(), parameterAliases(), parameterTypes(), 0, _
                    freeBasicType, -1, -1) = 0 OrElse _
                   hasFunctionCall <> 0 Then Return -1
            End If
            If valueIndex > 0 Then translatedValues &= ", "
            translatedValues &= translatedValue
        Next
        translatedText = "{" & translatedValues & "}"
        Return -1
    End If

    If Left(initializerText, 1) = "{" AndAlso _
       CBodyRecordName(translation, catalog, freeBasicType) <> "" Then
        Dim context As SimpleBodyContext
        Dim callableNames(0 To 0) As String
        Dim parameterNames(0 To 0) As String
        Dim parameterAliases(0 To 0) As String
        Dim parameterTypes(0 To 0) As String
        Dim recordInitializer As String
        If TranslateSimpleRecordInitializer( _
            translation, catalog, initializerText, freeBasicType, _
            recordInitializer, context, callableNames(), 0, parameterNames(), _
            parameterAliases(), parameterTypes(), 0) <> 0 Then
            translatedText = recordInitializer
            Return -1
        End If
    End If

    If LCase(Left(initializerText, 6)) = "sizeof" Then
        Dim callableNames(0 To 0) As String
        Dim parameterNames(0 To 0) As String
        Dim parameterAliases(0 To 0) As String
        Dim parameterTypes(0 To 0) As String
        Dim hasBooleanOperator As Long
        Dim hasFunctionCall As Long
        Dim scalarInitializer As String
        If TranslateSimpleExpression( _
            translation, catalog, initializerText, scalarInitializer, _
            hasBooleanOperator, hasFunctionCall, callableNames(), 0, _
            parameterNames(), parameterAliases(), parameterTypes(), 0, _
            freeBasicType, -1, -1) <> 0 AndAlso hasFunctionCall = 0 Then
            translatedText = scalarInitializer
        End If
    End If
    Return -1
End Function

Private Function C2fbBodyTextUsesCLongDouble( _
    ByVal sourceText As String _
) As Long
    Dim foldedText As String = LCase(sourceText)
    If InStr(foldedText, "clongdouble") <> 0 OrElse _
       InStr(foldedText, "fb_longdouble") <> 0 OrElse _
       InStr(foldedText, "long double") <> 0 Then Return -1
    Return 0
End Function

Private Function C2fbBodyOutputUsesCLongDouble( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long, _
    generatedRecordIsUsed() As Long, _
    ByVal keepUnresolvedDependencies As Long _
) As Long
    For candidateIndex As Long = 0 To candidateCount - 1
        If C2fbBodyCandidateWillBeEmitted( _
            candidates(candidateIndex)) = 0 Then Continue For
        With candidates(candidateIndex)
            If C2fbBodyTextUsesCLongDouble(.source) <> 0 OrElse _
               C2fbBodyTextUsesCLongDouble( _
                   .procedureBinding.returnType & "|" & _
                   .procedureBinding.parameterList) <> 0 Then Return -1
        End With
    Next
    If C2fbBodyTextUsesCLongDouble( _
        translation.body.generatedStaticDeclarations) <> 0 Then Return -1

    For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
        With translation.symbolTable.symbols(symbolIndex)
            If .body.isDeclared = 0 OrElse .body.isAmbiguous <> 0 OrElse _
               .ambiguous <> 0 Then Continue For
            Dim freeBasicName As String = _
                CBodySymbolFreeBasicName(translation, catalog, symbolIndex)
            Dim callName As String = _
                CBodyCallName(translation, catalog, .sourceName)
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) = 0 Then Continue For
                If CBodyUsesProcedure( _
                    candidates(candidateIndex).source, .sourceName) <> 0 OrElse _
                   CBodyUsesProcedure( _
                    candidates(candidateIndex).source, freeBasicName) <> 0 OrElse _
                   (callName <> "" AndAlso CBodyUsesProcedure( _
                    candidates(candidateIndex).source, callName) <> 0) Then
                    If C2fbBodyTextUsesCLongDouble( _
                           .body.returnType & "|" & .body.parameterTypes) <> 0 Then _
                        Return -1
                    Exit For
                End If
            Next
        End With
    Next

    For signatureIndex As Long = 0 To catalog.bodyCallSignatureCount - 1
        With catalog.bodyCallSignatures(signatureIndex)
            If .parameterCount < 0 Then Continue For
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) = 0 Then Continue For
                If CBodyUsesProcedure( _
                    candidates(candidateIndex).source, .name) <> 0 OrElse _
                   CBodyUsesProcedure( _
                    candidates(candidateIndex).source, .fbName) <> 0 Then
                    If C2fbBodyTextUsesCLongDouble( _
                           .returnType & "|" & .parameterTypes) <> 0 Then _
                        Return -1
                    Exit For
                End If
            Next
        End With
    Next

    For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
        With translation.body.externalObjects(objectIndex)
            If .isAmbiguous <> 0 OrElse .isReused <> 0 Then Continue For
            Dim objectIsUsed As Long = CInt( _
                translation.body.includeGlobalDefinitions <> 0 AndAlso _
                .isDefinition <> 0 AndAlso .isStatic = 0) * -1
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) = 0 Then Continue For
                If CBodyUsesIdentifier( _
                    candidates(candidateIndex).source, .freeBasicName) <> 0 OrElse _
                   (.sourceName <> "" AndAlso CBodyUsesIdentifier( _
                    candidates(candidateIndex).source, .sourceName) <> 0) Then
                    objectIsUsed = -1
                    Exit For
                End If
            Next
            If objectIsUsed <> 0 AndAlso ( _
               C2fbBodyTextUsesCLongDouble(.freeBasicType) <> 0 OrElse _
               C2fbBodyTextUsesCLongDouble(.initializerText) <> 0) Then _
                Return -1
        End With
    Next

    For bindingIndex As Long = 0 To translation.body.recordBindingCount - 1
        If bindingIndex > UBound(generatedRecordIsUsed) OrElse _
           generatedRecordIsUsed(bindingIndex) = 0 OrElse _
           translation.body.recordBindings(bindingIndex).isGenerated = 0 Then _
            Continue For
        With translation.body.recordBindings(bindingIndex)
            For fieldIndex As Long = 0 To catalog.bodyFieldCount - 1
                If catalog.bodyFields(fieldIndex).ownerName = .fbName AndAlso _
                   C2fbBodyTextUsesCLongDouble( _
                       catalog.bodyFields(fieldIndex).typeName) <> 0 Then _
                    Return -1
            Next
        End With
    Next

    For callbackIndex As Long = 0 To translation.body.callbackCount - 1
        With translation.body.callbacks(callbackIndex)
            Dim callbackIsUsed As Long = 0
            For candidateIndex As Long = 0 To candidateCount - 1
                If C2fbBodyCandidateWillBeEmitted( _
                    candidates(candidateIndex)) <> 0 AndAlso _
                   InStr(candidates(candidateIndex).source, .fbType) <> 0 Then
                    callbackIsUsed = -1
                    Exit For
                End If
            Next
            If callbackIsUsed = 0 Then Continue For
            If C2fbBodyTextUsesCLongDouble( _
                .declaration & "|" & .returnType & "|" & _
                .parameterTypes) <> 0 Then Return -1
        End With
    Next

    If keepUnresolvedDependencies <> 0 Then
        For candidateIndex As Long = 0 To candidateCount - 1
            With candidates(candidateIndex)
                If .source <> "" OrElse .duplicate <> 0 OrElse _
                   .procedureBinding.freeBasicName = "" Then Continue For
                If C2fbBodyTextUsesCLongDouble( _
                    .procedureBinding.returnType & "|" & _
                    .procedureBinding.parameterList) = 0 Then Continue For
                For callerIndex As Long = 0 To candidateCount - 1
                    If C2fbBodyCandidateWillBeEmitted( _
                        candidates(callerIndex)) = 0 Then Continue For
                    If CBodyUsesProcedure( _
                        candidates(callerIndex).source, .name) <> 0 OrElse _
                       CBodyUsesProcedure( _
                        candidates(callerIndex).source, _
                        .procedureBinding.freeBasicName) <> 0 Then Return -1
                Next
            End With
        Next
    End If
    Return 0
End Function


Private Sub WriteC2fbBodyCandidateFile( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputModel As C2fbBodyCandidateFileModel, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long _
)
    If C2fbTargetProfileIsValid(translation.target.profile) = 0 Then _
        ReportError("body candidate output has no active target profile")
    Dim fileOutput As C2fbGeneratedFileOutputModel
    If OpenC2fbGeneratedFileOutput(fileOutput, outputModel.outputPath) = 0 Then _
        ReportError("cannot write body candidate file: " & outputModel.outputPath)
    Dim fileComment As C2fbGeneratedFileCommentModel
    ResetC2fbGeneratedFileComment(fileComment)
    If translation.target.profile = C2FB_TARGET_SQLITE Then
        If AddC2fbGeneratedFileCommentLine( _
            fileComment, "    Project: SQLite FreeBASIC port") = 0 Then _
            ReportError("body candidate file comment exceeds its limit")
    Else
        If AddC2fbGeneratedFileCommentLine( _
            fileComment, "    Project: C2FB general C body candidates") = 0 Then _
            ReportError("body candidate file comment exceeds its limit")
    End If
    If AddC2fbGeneratedFileCommentLine(fileComment, "") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    File: " & FileNameOnly(outputModel.outputPath)) = 0 OrElse _
       AddC2fbGeneratedFileCommentLine(fileComment, "") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    Purpose: Hold conservative translations of C function candidates.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    Source: " & outputModel.sourceLabel) = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    Generated by fb_tools/c2fb/c2fb.bas; review before integration.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine(fileComment, "") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "    This file intentionally does NOT contain:") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "        - Macros, indirect function-pointer calls, unsupported static pointer initializers, aggregate forms, or statements.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "        - Functions inside preprocessor-conditional source regions.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
           fileComment, "        - Functions whose C types or expressions are outside the supported subset.") = 0 Then _
        ReportError("body candidate file comment exceeds its limit")
    If outputModel.keepUnresolvedDependencies <> 0 Then _
        If AddC2fbGeneratedFileCommentLine( _
            fileComment, "        - Bodies may call source-local helpers that C2FB could not translate.") = 0 Then _
            ReportError("body candidate file comment exceeds its limit")
    If outputModel.assertionsStripped <> 0 Then _
        If AddC2fbGeneratedFileCommentLine( _
            fileComment, "        - C assert() checks were suppressed for translation; restore required invariants before integration.") = 0 Then _
            ReportError("body candidate file comment exceeds its limit")
    Dim generatedRecordIsUsed(Any) As Long
    IndexCBodyGeneratedLocalRecordUsage( _
        translation, catalog, candidates(), candidateCount, _
        generatedRecordIsUsed())
    Dim filePreamble As C2fbGeneratedFilePreambleModel
    If AddC2fbGeneratedFilePreambleBlank(filePreamble) = 0 Then _
        ReportError("body candidate preamble exceeds its configured limit")
    If translation.target.profile = C2FB_TARGET_SQLITE Then
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "crt/stddef.bi") = 0 OrElse _
           AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_types.bi") = 0 OrElse _
           AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_constants.bi") = 0 OrElse _
           AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_db_types.bi") = 0 Then _
            ReportError("body candidate preamble exceeds its configured limit")
        If outputModel.fbSourceDirectory = "" Then
            If AddC2fbGeneratedFileIncludeOnce( _
                filePreamble, "sqlite3_api_declarations.bi") = 0 OrElse _
               AddC2fbGeneratedFileIncludeOnce( _
                filePreamble, "sqlite3_internal_api_declarations.bi") = 0 Then _
                ReportError("body candidate preamble exceeds its configured limit")
        End If
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_parser_types.bi") = 0 OrElse _
           AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_expr_types.bi") = 0 OrElse _
           AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_vdbe_mem_types.bi") = 0 OrElse _
           AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_vdbe_core.bi") = 0 OrElse _
           AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_hash_types.bi") = 0 OrElse _
           AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_pager.bi") = 0 OrElse _
           AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "sqlite3_btree.bi") = 0 Then _
            ReportError("body candidate preamble exceeds its configured limit")
    Else
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "crt/stddef.bi") = 0 OrElse _
           AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "crt/long.bi") = 0 Then _
            ReportError("body candidate preamble exceeds its configured limit")
        If C2fbBodyOutputUsesCLongDouble( _
            translation, catalog, candidates(), candidateCount, _
            generatedRecordIsUsed(), outputModel.keepUnresolvedDependencies) <> 0 Then
            If AddC2fbGeneratedFileIncludeOnce( _
                filePreamble, "crt/longdouble.bi") = 0 Then _
                ReportError("body candidate preamble exceeds its configured limit")
        End If
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "crt/stdarg.bi") = 0 Then _
            ReportError("body candidate preamble exceeds its configured limit")
    End If
    If translation.body.atomicMutexRuntime <> 0 Then
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "fbc-int/system.bi") = 0 Then _
            ReportError("body candidate preamble exceeds its configured limit")
    End If
    Dim usesBuiltinMath As Long = 0
    For candidateIndex As Long = 0 To candidateCount - 1
        If C2fbBodyCandidateWillBeEmitted(candidates(candidateIndex)) = 0 Then _
            Continue For
        If InStr(candidates(candidateIndex).source, "INFINITY") <> 0 OrElse _
           InStr(candidates(candidateIndex).source, "HUGE_VALF") <> 0 OrElse _
           InStr(candidates(candidateIndex).source, "NAN_") <> 0 Then
            usesBuiltinMath = -1
            Exit For
        End If
    Next
    If (outputModel.fbSourceDirectory = "" AndAlso _
        C2fbBodyUsesRuntimeMath( _
            translation, catalog, candidates(), candidateCount) <> 0) OrElse _
       usesBuiltinMath <> 0 Then
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "crt/math.bi") = 0 Then _
            ReportError("body candidate preamble exceeds its configured limit")
    End If
    Dim needsHalfFloatConversionHelpers As Long = 0
    For candidateIndex As Long = 0 To candidateCount - 1
        If C2fbBodyCandidateWillBeEmitted(candidates(candidateIndex)) = 0 Then _
            Continue For
        If InStr(candidates(candidateIndex).source, _
                 "c2fb_float16_to_single") <> 0 OrElse _
           InStr(candidates(candidateIndex).source, _
                 "c2fb_bfloat16_to_single") <> 0 Then
            needsHalfFloatConversionHelpers = -1
            Exit For
        End If
    Next
    If CBodyUsesCrtMemory( _
        translation, candidates(), candidateCount) <> 0 OrElse _
       needsHalfFloatConversionHelpers <> 0 Then
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "crt/mem.bi") = 0 Then _
            ReportError("body candidate preamble exceeds its configured limit")
    End If
    If AddC2fbGeneratedFilePreambleBlank(filePreamble) = 0 Then _
        ReportError("body candidate preamble exceeds its configured limit")
    If Len(outputModel.fbSourceDirectory) <> 0 Then
        WriteCandidateIncludes( _
            translation, catalog, translation.target.profile, filePreamble, _
            outputModel.fbSourceDirectory, candidates(), candidateCount)
        If AddC2fbGeneratedFilePreambleBlank(filePreamble) = 0 Then _
            ReportError("body candidate preamble exceeds its configured limit")
    End If
    Dim includedDeclarationNames As C2fbNameSetModel
    IndexC2fbCandidateIncludedDeclarations( _
        filePreamble, outputModel.fbSourceDirectory, includedDeclarationNames)
    WriteC2fbGeneratedFilePreamble(fileOutput, fileComment, filePreamble)
    WriteCBodyAbiTypeAliases(translation, fileOutput)
    WriteCBodyCallbackDeclarations( _
        translation, catalog, fileOutput, candidates(), candidateCount, _
        generatedRecordIsUsed())
    If Len(outputModel.fbSourceDirectory) <> 0 Then
        ' These generated API declaration files belong to the SQLite port tree.
        If translation.target.profile = C2FB_TARGET_SQLITE Then _
            WriteCandidateDeclarations( _
                fileOutput, outputModel.fbSourceDirectory, _
                candidates(), candidateCount, includedDeclarationNames)
        WriteExistingBodyDeclarations( _
            catalog, fileOutput, includedDeclarationNames, _
            candidates(), candidateCount)
        WriteC2fbGeneratedFileLine(fileOutput, "")
    End If
    WriteCBodyGeneratedLocalRecordTypes( _
        translation, catalog, fileOutput, generatedRecordIsUsed())
    WriteCBodyCallbackDeclarations( _
        translation, catalog, fileOutput, candidates(), candidateCount, _
        generatedRecordIsUsed(), -1)
    WriteCBodyDeclarations( _
        translation, catalog, fileOutput, candidates(), candidateCount, _
        includedDeclarationNames, _
        outputModel.keepUnresolvedDependencies)
    If needsHalfFloatConversionHelpers <> 0 Then _
        WriteC2fbHalfFloatConversionHelpers(fileOutput)

    Dim conversionSummary As C2fbConversionSummaryModel
    Dim unsupportedCandidateCount As Long = 0
    Dim duplicateCandidateCount As Long = 0
    Dim dependencyCandidateCount As Long = 0
    Dim existingBodyCandidateCount As Long = 0
    Dim otherSkippedCandidateCount As Long = 0
    For candidateIndex As Long = 0 To candidateCount - 1
        If candidates(candidateIndex).isHeaderBody <> 0 AndAlso _
           candidates(candidateIndex).isHeaderRequired = 0 Then Continue For
        If candidates(candidateIndex).skipMessage <> "" Then
            Select Case candidates(candidateIndex).skipMessage
            Case "outside the supported subset"
                unsupportedCandidateCount += 1
            Case "multiple source definitions"
                duplicateCandidateCount += 1
            Case "FreeBASIC body already exists"
                existingBodyCandidateCount += 1
            Case Else
                If Left(candidates(candidateIndex).skipMessage, _
                        Len("requires ")) = "requires " Then
                    dependencyCandidateCount += 1
                Else
                    otherSkippedCandidateCount += 1
                End If
            End Select
            EmitC2fbSkippedAtLocation(translation, fileOutput, conversionSummary, _
                candidates(candidateIndex).name & ": " & _
                candidates(candidateIndex).skipMessage, "", _
                candidates(candidateIndex).sourceLocation)
            If candidates(candidateIndex).skipMessage = _
               "outside the supported subset" Then
                For diagnosticIndex As Long = candidates(candidateIndex).diagnosticStart To _
                    candidates(candidateIndex).diagnosticStart + _
                    candidates(candidateIndex).diagnosticCount - 1
                    If diagnosticIndex < 0 OrElse _
                       diagnosticIndex >= translation.sourceUnit.diagnosticState.diagnosticCount Then _
                        Continue For
                    WriteC2fbBodyCandidateDiagnostic( _
                        fileOutput, _
                        translation.sourceUnit.diagnosticState.diagnostics(diagnosticIndex))
                Next
            End If
        Else
            WriteC2fbBodyCandidateSource( _
                fileOutput, candidates(candidateIndex))
            WriteC2fbGeneratedFileLine(fileOutput, "")
            conversionSummary.convertedCount += 1
        End If
    Next
    WriteC2fbBodyRenameReport(translation, fileOutput)
    WriteC2fbGeneratedFileEndMarker(fileOutput)
    CloseC2fbGeneratedFileOutput(fileOutput)
    If C2fbGeneratedFileOutputHasFailed(fileOutput) <> 0 Then _
        ReportError(C2fbGeneratedFileOutputFailureMessage( _
            fileOutput, "cannot finish body candidate file: " & outputModel.outputPath))
    Print "translated " & Trim(Str(conversionSummary.convertedCount)) & _
        " simple functions; skipped " & Trim(Str(conversionSummary.skippedCount)) & _
        " unsupported or duplicate candidates; output " & outputModel.outputPath
    If conversionSummary.skippedCount > 0 Then
        If unsupportedCandidateCount + duplicateCandidateCount + _
           dependencyCandidateCount + existingBodyCandidateCount + _
           otherSkippedCandidateCount <> conversionSummary.skippedCount Then _
            ReportError("body candidate skip summary is inconsistent")
        Print "c2fb candidate skips: unsupported=" & _
            Trim(Str(unsupportedCandidateCount)) & ", duplicates=" & _
            Trim(Str(duplicateCandidateCount)) & ", dependencies=" & _
            Trim(Str(dependencyCandidateCount)) & ", already-ported=" & _
            Trim(Str(existingBodyCandidateCount)) & ", other=" & _
            Trim(Str(otherSkippedCandidateCount))
    End If
    If outputModel.keepUnresolvedDependencies <> 0 Then _
        Print "c2fb: kept callers with unsupported source-local helper dependencies"
End Sub

/' end of c2fb_body_output.bi '/
