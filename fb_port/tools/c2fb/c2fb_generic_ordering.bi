/'
    Project: C2FB generic header converter

    File: c2fb_generic_ordering.bi

    Purpose:

        Apply caller-selected ordering to generic-header declarations.

    Responsibilities:

        - Find top-level C declarations by C or generated FreeBASIC name.
        - Reorder declarations within a compatible output phase.
        - Hoist scalar externals, built-in prototypes, and requested forward-tag pointers before a simple typedef.
        - Keep other type, record, enum, and external declaration dependencies intact.
        - Report unused and incompatible move requests in generated output.

    This file intentionally does NOT contain:

        - Declaration parsing, source preprocessing, or binding emission.
        - Reordering of macro definitions or inline function macros.
'/

Private Const C2FB_MOVE_PHASE_INVALID As Long = 0
Private Const C2FB_MOVE_PHASE_TYPEDEF As Long = 1
Private Const C2FB_MOVE_PHASE_RECORD As Long = 2
Private Const C2FB_MOVE_PHASE_ENUM As Long = 3
Private Const C2FB_MOVE_PHASE_DECLARATION As Long = 4

Private Function GenericMoveAboveNameMatches( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourceName As String, ByVal requestedName As String _
) As Long
    If sourceName = "" OrElse requestedName = "" Then Return 0
    If sourceName = requestedName OrElse _
       policy.generatedNamePrefix & sourceName = requestedName Then Return -1
    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        If policy.symbolRenames(renameIndex).sourceName = sourceName AndAlso _
           policy.symbolRenames(renameIndex).freeBasicName = requestedName Then _
            Return -1
    Next
    Return 0
End Function

Private Function GenericMoveAboveDeclarationHasName( _
    ByRef translation As C2fbTranslationContext, _
    ByRef declaration As C2fbDeclarationModel, ByVal requestedName As String _
) As Long
    If declaration.entryKind = C2FB_DECLARATION_FUNCTION Then
        If declaration.isFunctionDefinition <> 0 Then Return 0
        For tokenIndex As Long = 0 To declaration.tokenCount - 1
            If declaration.tokens(tokenIndex) = "static" Then Return 0
        Next
        If GenericProcedureExcludedInPolicy( _
            translation.genericC.policy, declaration.sourceName) <> 0 Then Return 0
        Return GenericMoveAboveNameMatches( _
            translation.genericC.policy, declaration.sourceName, requestedName)
    End If

    If declaration.entryKind = C2FB_DECLARATION_RECORD Then
        If (declaration.recordTag <> "" AndAlso _
            GenericTypeExcludedInPolicy( _
                translation.genericC.policy, declaration.recordTag) <> 0) OrElse _
           (declaration.recordAlias <> "" AndAlso _
            GenericTypeExcludedInPolicy( _
                translation.genericC.policy, declaration.recordAlias) <> 0) Then Return 0
        If GenericMoveAboveNameMatches( _
            translation.genericC.policy, declaration.recordTag, requestedName) <> 0 OrElse _
           GenericMoveAboveNameMatches( _
            translation.genericC.policy, declaration.recordAlias, requestedName) <> 0 Then _
            Return -1
        Return 0
    End If

    If declaration.entryKind <> C2FB_DECLARATION_PLAIN OrElse _
       declaration.text = "" Then Return 0
    If declaration.tokenCount > 0 AndAlso _
       declaration.tokens(0) <> "typedef" Then
        For tokenIndex As Long = 0 To declaration.tokenCount - 1
            If declaration.tokens(tokenIndex) = "static" Then Return 0
        Next
    End If
    Dim declarationParts() As String
    Dim declarationPartCount As Long = 0
    If SplitSimpleCList( _
        declaration.text, declarationParts(), declarationPartCount) = 0 OrElse _
       declarationPartCount = 0 Then Return 0

    Dim commonType As String
    Dim firstName As String
    Dim firstBinding As String
    If ParseGenericHeaderDeclarator( _
        declarationParts(0), commonType, firstName, firstBinding) = 0 Then Return 0
    For partIndex As Long = 0 To declarationPartCount - 1
        Dim sourceName As String = firstName
        If partIndex > 0 Then
            Dim itemDeclaration As String = commonType & " " & _
                Trim(declarationParts(partIndex))
            Dim itemCommonType As String
            Dim itemBinding As String
            If ParseGenericHeaderDeclarator( _
                itemDeclaration, itemCommonType, sourceName, itemBinding) = 0 Then _
                Continue For
        End If
        If declaration.tokenCount > 0 AndAlso _
           declaration.tokens(0) = "typedef" Then
            If GenericTypeExcludedInPolicy( _
                translation.genericC.policy, sourceName) <> 0 Then Continue For
        ElseIf GenericVariableExcludedInPolicy( _
            translation.genericC.policy, sourceName) <> 0 Then
            Continue For
        End If
        If GenericMoveAboveNameMatches( _
            translation.genericC.policy, sourceName, requestedName) <> 0 Then Return -1
    Next
    Return 0
End Function

Private Function GenericMoveAboveDeclarationPhase( _
    ByRef declaration As C2fbDeclarationModel _
) As Long
    Select Case declaration.entryKind
    Case C2FB_DECLARATION_FUNCTION
        Return C2FB_MOVE_PHASE_DECLARATION
    Case C2FB_DECLARATION_PLAIN
        For tokenIndex As Long = 0 To declaration.tokenCount - 1
            If declaration.tokens(tokenIndex) = "typedef" Then _
                Return C2FB_MOVE_PHASE_TYPEDEF
        Next
        Return C2FB_MOVE_PHASE_DECLARATION
    Case C2FB_DECLARATION_RECORD
        If declaration.recordKind = C2FB_RECORD_ENUM Then _
            Return C2FB_MOVE_PHASE_ENUM
        Return C2FB_MOVE_PHASE_RECORD
    End Select
    Return C2FB_MOVE_PHASE_INVALID
End Function

Private Function GenericMoveAboveTypeIsBuiltin( _
    ByVal sourceType As String, ByVal allowTypedef As Long _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceType, tokens(), tokenCount)
    If tokenCount <= 0 Then Return 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case tokens(tokenIndex)
        Case "extern", "register", "const", "volatile", "restrict", _
             "_Atomic", "signed", "unsigned", "char", "short", "int", _
             "long", "float", "double", "_Bool", "void", _
             "__extension__", "__const", "__volatile", "__restrict"
        Case "typedef"
            If allowTypedef = 0 Then Return 0
        Case Else
            Return 0
        End Select
    Next
    Return -1
End Function

Private Function GenericMoveAboveTypeHasRequestedRecordForward( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByVal pointerDepth As Long _
) As Long
    If pointerDepth <= 0 OrElse _
       pointerDepth > MAX_FREEBASIC_POINTER_LEVELS Then Return 0
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceType, tokens(), tokenCount)
    If tokenCount <= 0 Then Return 0

    Dim tagName As String
    Dim tokenIndex As Long = 0
    While tokenIndex < tokenCount
        Select Case tokens(tokenIndex)
        Case "extern", "register", "const", "volatile", "restrict", _
             "_Atomic", "__extension__", "__const", "__volatile", "__restrict"
            tokenIndex += 1
        Case "struct", "union"
            If tagName <> "" OrElse tokenIndex + 1 >= tokenCount OrElse _
               IsIdentifierToken(tokens(tokenIndex + 1)) = 0 Then Return 0
            tagName = tokens(tokenIndex + 1)
            tokenIndex += 2
        Case Else
            Return 0
        End Select
    Wend
    If tagName = "" OrElse GenericTypeExcludedInPolicy( _
        translation.genericC.policy, tagName) <> 0 Then Return 0

    For patternIndex As Long = 0 To _
        translation.genericC.policy.forwardDeclarationPatternCount - 1
        If GenericIdentifierMatchesPattern( _
            tagName, translation.genericC.policy.forwardDeclarationPatterns( _
                patternIndex).pattern) <> 0 Then Return -1
    Next
    Return 0
End Function

Private Function GenericMoveAboveCanHoistPlainObject( _
    ByRef translation As C2fbTranslationContext, _
    ByRef declaration As C2fbDeclarationModel, _
    ByVal isTypedef As Long, ByVal requestedName As String _
) As Long
    If declaration.entryKind <> C2FB_DECLARATION_PLAIN OrElse _
       declaration.text = "" OrElse declaration.isFunctionDefinition <> 0 OrElse _
       InStr(declaration.text, "(") <> 0 OrElse _
       InStr(declaration.text, "[") <> 0 OrElse _
       InStr(declaration.text, "=") <> 0 Then Return 0
    If declaration.tokenCount <= 0 Then Return 0
    If CInt(declaration.tokens(0) = "typedef") <> isTypedef Then Return 0
    For tokenIndex As Long = 0 To declaration.tokenCount - 1
        If declaration.tokens(tokenIndex) = "static" Then Return 0
    Next

    Dim declarationParts() As String
    Dim declarationPartCount As Long = 0
    If SplitSimpleCList( _
        declaration.text, declarationParts(), declarationPartCount) = 0 OrElse _
       declarationPartCount <> 1 Then Return 0
    Dim commonType As String
    Dim sourceName As String
    Dim binding As String
    If ParseGenericHeaderDeclarator( _
        declarationParts(0), commonType, sourceName, binding) = 0 OrElse _
       GenericMoveAboveNameMatches( _
        translation.genericC.policy, sourceName, requestedName) = 0 Then Return 0
    Dim pointerDepth As Long = 0
    For bindingIndex As Long = 1 To Len(binding)
        If Mid(binding, bindingIndex, 1) <> "P" Then Return 0
        pointerDepth += 1
    Next
    If pointerDepth > MAX_FREEBASIC_POINTER_LEVELS Then Return 0
    If GenericMoveAboveTypeIsBuiltin(commonType, isTypedef) <> 0 Then Return -1
    If isTypedef <> 0 Then Return 0
    Return GenericMoveAboveTypeHasRequestedRecordForward( _
        translation, commonType, pointerDepth)
End Function

Private Function GenericMoveAboveIsSimpleBuiltinFunctionPrototype( _
    ByRef translation As C2fbTranslationContext, _
    ByRef declaration As C2fbDeclarationModel, ByVal requestedName As String _
) As Long
    If declaration.entryKind <> C2FB_DECLARATION_FUNCTION OrElse _
       declaration.isFunctionDefinition <> 0 OrElse _
       declaration.isConditional <> 0 OrElse declaration.tokenCount <= 0 OrElse _
       declaration.functionDeclaration.declarator.operatorCount < 1 OrElse _
       declaration.functionDeclaration.declarator.operatorKind(0) <> _
           C2FB_DECLARATOR_FUNCTION OrElse _
       GenericMoveAboveNameMatches( _
           translation.genericC.policy, declaration.sourceName, requestedName) = 0 Then _
        Return 0

    Dim returnPointerDepth As Long = 0
    For operatorIndex As Long = 1 To _
        declaration.functionDeclaration.declarator.operatorCount - 1
        If declaration.functionDeclaration.declarator.operatorKind(operatorIndex) <> _
           C2FB_DECLARATOR_POINTER Then Return 0
        returnPointerDepth += 1
    Next
    If returnPointerDepth > MAX_FREEBASIC_POINTER_LEVELS Then Return 0

    Dim declaratorStart As Long = _
        declaration.functionDeclaration.declaratorStartToken
    If declaratorStart <= 0 OrElse declaratorStart > MAX_TYPE_WORDS Then Return 0
    Dim returnTypeTokens() As String
    ReDim returnTypeTokens(0 To declaratorStart - 1)
    For tokenIndex As Long = 0 To declaratorStart - 1
        If declaration.tokens(tokenIndex) = "static" Then Return 0
        returnTypeTokens(tokenIndex) = declaration.tokens(tokenIndex)
    Next
    Dim returnType As String = _
        GenericTokensToText(returnTypeTokens(), 0, declaratorStart - 1)
    If GenericMoveAboveTypeIsBuiltin(returnType, 0) = 0 AndAlso _
       GenericMoveAboveTypeHasRequestedRecordForward( _
            translation, returnType, returnPointerDepth) = 0 Then Return 0

    Dim openToken As Long = _
        declaration.functionDeclaration.declarator.firstFunctionOpenToken
    Dim closePosition As Long = openToken
    If openToken < 0 OrElse SkipCDeclaratorGroup( _
        declaration.tokens(), closePosition, declaration.tokenCount - 1, "(", ")") = 0 Then _
        Return 0
    Dim closeToken As Long = closePosition - 1
    If closeToken = openToken + 2 AndAlso _
       declaration.tokens(openToken + 1) = "void" Then Return -1
    If openToken + 1 > closeToken - 1 Then Return 0

    Dim parameterRanges() As C2fbTokenRangeModel
    Dim parameterRangeCount As Long
    If SplitC2fbTokenList( _
        declaration.tokens(), openToken + 1, closeToken - 1, _
        parameterRanges(), parameterRangeCount) = 0 Then Return 0
    For parameterIndex As Long = 0 To parameterRangeCount - 1
        Dim firstToken As Long = parameterRanges(parameterIndex).firstToken
        Dim lastToken As Long = parameterRanges(parameterIndex).lastToken
        For tokenIndex As Long = firstToken To lastToken
            If declaration.tokens(tokenIndex) = "(" OrElse _
               declaration.tokens(tokenIndex) = "[" Then Return 0
        Next
        If firstToken = lastToken AndAlso _
           GenericMoveAboveTypeIsBuiltin( _
            declaration.tokens(firstToken), 0) <> 0 Then Continue For
        Dim commonType As String
        Dim parameterName As String
        Dim binding As String
        Dim commonTypeTokenCount As Long
        If ParseGenericHeaderDeclaratorTokens( _
            declaration.tokens(), firstToken, lastToken, commonType, _
            parameterName, binding, commonTypeTokenCount) = 0 Then Return 0
        Dim parameterPointerDepth As Long = 0
        For bindingIndex As Long = 1 To Len(binding)
            If Mid(binding, bindingIndex, 1) <> "P" Then Return 0
            parameterPointerDepth += 1
        Next
        If parameterPointerDepth > MAX_FREEBASIC_POINTER_LEVELS Then Return 0
        If GenericMoveAboveTypeIsBuiltin(commonType, 0) = 0 AndAlso _
           GenericMoveAboveTypeHasRequestedRecordForward( _
                translation, commonType, parameterPointerDepth) = 0 Then Return 0
    Next
    Return -1
End Function

Private Function FindGenericMoveAboveDeclaration( _
    ByRef translation As C2fbTranslationContext, ByVal requestedName As String _
) As Long
    Dim resultIndex As Long = -1
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .removeFromGenericHeader <> 0 OrElse _
               GenericSourceIncludedInPolicy( _
                translation.genericC.policy, .sourceSpan.startLocation.path) = 0 Then _
                Continue For
            If GenericMoveAboveDeclarationHasName( _
                translation, translation.sourceUnit.declarations(declarationIndex), _
                requestedName) <> 0 Then resultIndex = declarationIndex
        End With
    Next
    Return resultIndex
End Function

Private Function GenericMoveAboveDeclarationWasHoisted( _
    ByRef translation As C2fbTranslationContext, _
    ByRef declaration As C2fbDeclarationModel _
) As Long
    For moveIndex As Long = 0 To _
        translation.genericC.policy.moveAboveCount - 1
        With translation.genericC.policy.moveAboveMappings(moveIndex)
            If .hoisted <> 0 AndAlso .applied <> 0 AndAlso _
               GenericMoveAboveDeclarationHasName( _
                translation, declaration, .movingName) <> 0 Then Return -1
        End With
    Next
    Return 0
End Function

Private Sub EmitGenericHeaderHoistedExternalDeclarations( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef referenceDeclaration As C2fbDeclarationModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    names() As String, ByRef nameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For moveIndex As Long = 0 To _
        translation.genericC.policy.moveAboveCount - 1
        With translation.genericC.policy.moveAboveMappings(moveIndex)
            If .hoisted = 0 OrElse .applied <> 0 OrElse _
               GenericMoveAboveDeclarationHasName( _
                translation, referenceDeclaration, .referenceName) = 0 Then _
                Continue For
            Dim movingIndex As Long = FindGenericMoveAboveDeclaration( _
                translation, .movingName)
            If movingIndex < 0 Then
                .failureReason = "hoisted declaration is unavailable"
                Continue For
            End If
            With translation.sourceUnit.declarations(movingIndex)
                translation.sourceUnit.diagnosticState.currentSourceLocation.path = _
                    .sourceSpan.startLocation.path
                translation.sourceUnit.diagnosticState.currentSourceLocation.line = _
                    .sourceSpan.startLocation.line
                translation.sourceUnit.diagnosticState.currentSourceLocation.column = _
                    .sourceSpan.startLocation.column
                If .entryKind = C2FB_DECLARATION_FUNCTION Then
                    EmitPrototypeModel( _
                        translation, catalog, _
                        translation.sourceUnit.declarations(movingIndex), _
                        outputFile, names(), nameCount, outputNames(), _
                        outputNameCount, conversionSummary, _
                        C2FB_TYPE_MAPPING_GENERIC_HEADER)
                Else
                    EmitGenericHeaderDeclaration( _
                        translation, catalog, _
                        translation.sourceUnit.declarations(movingIndex), _
                        outputFile, names(), nameCount, outputNames(), _
                        outputNameCount, conversionSummary)
                End If
            End With
            .applied = -1
        End With
    Next
    translation.sourceUnit.diagnosticState.currentSourceLocation.path = _
        referenceDeclaration.sourceSpan.startLocation.path
    translation.sourceUnit.diagnosticState.currentSourceLocation.line = _
        referenceDeclaration.sourceSpan.startLocation.line
    translation.sourceUnit.diagnosticState.currentSourceLocation.column = _
        referenceDeclaration.sourceSpan.startLocation.column
End Sub

Private Sub ApplyGenericMoveAboveToDeclarationParts( _
    ByRef translation As C2fbTranslationContext, _
    parts() As String, ByVal partCount As Long, ByVal commonType As String, _
    partOrder() As Long _
)
    If partCount <= 0 Then Exit Sub
    ReDim partOrder(0 To partCount - 1)
    For partIndex As Long = 0 To partCount - 1
        partOrder(partIndex) = partIndex
    Next
    If translation.genericC.policy.moveAboveCount = 0 Then Exit Sub

    Dim partNames() As String
    ReDim partNames(0 To partCount - 1)
    For partIndex As Long = 0 To partCount - 1
        Dim declarationText As String = Trim(parts(partIndex))
        If partIndex > 0 Then declarationText = commonType & " " & declarationText
        Dim itemCommonType As String
        Dim itemSourceName As String
        Dim itemBinding As String
        If ParseGenericHeaderDeclarator( _
            declarationText, itemCommonType, itemSourceName, itemBinding) <> 0 Then _
            partNames(partIndex) = itemSourceName
    Next

    For moveIndex As Long = 0 To _
        translation.genericC.policy.moveAboveCount - 1
        With translation.genericC.policy.moveAboveMappings(moveIndex)
            If .applied <> 0 OrElse .failureReason <> "" Then Continue For
            Dim movingPosition As Long = -1
            Dim referencePosition As Long = -1
            For orderIndex As Long = 0 To partCount - 1
                Dim currentPart As Long = partOrder(orderIndex)
                If GenericMoveAboveNameMatches( _
                    translation.genericC.policy, partNames(currentPart), _
                    .movingName) <> 0 Then movingPosition = orderIndex
                If GenericMoveAboveNameMatches( _
                    translation.genericC.policy, partNames(currentPart), _
                    .referenceName) <> 0 Then referencePosition = orderIndex
            Next
            If movingPosition < 0 OrElse referencePosition < 0 Then Continue For
            .matched = -1
            If movingPosition = referencePosition Then
                .failureReason = "both names resolve to one declarator"
                Continue For
            End If
            If movingPosition > referencePosition Then
                Dim movingPart As Long = partOrder(movingPosition)
                For orderIndex As Long = movingPosition To referencePosition + 1 Step -1
                    partOrder(orderIndex) = partOrder(orderIndex - 1)
                Next
                partOrder(referencePosition) = movingPart
            End If
            .applied = -1
        End With
    Next
End Sub

Private Sub MoveGenericDeclarationAbove( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByVal movingIndex As Long, ByVal referenceIndex As Long _
)
    If movingIndex <= referenceIndex Then Exit Sub
    Dim movingDeclaration As C2fbDeclarationModel = _
        sourceUnit.declarations(movingIndex)
    For declarationIndex As Long = movingIndex To referenceIndex + 1 Step -1
        sourceUnit.declarations(declarationIndex) = _
            sourceUnit.declarations(declarationIndex - 1)
    Next
    sourceUnit.declarations(referenceIndex) = movingDeclaration
End Sub

Private Sub ApplyGenericMoveAboveToSourceUnit( _
    ByRef translation As C2fbTranslationContext _
)
    For moveIndex As Long = 0 To _
        translation.genericC.policy.moveAboveCount - 1
        With translation.genericC.policy.moveAboveMappings(moveIndex)
            Dim movingIndex As Long = FindGenericMoveAboveDeclaration( _
                translation, .movingName)
            Dim referenceIndex As Long = FindGenericMoveAboveDeclaration( _
                translation, .referenceName)
            If movingIndex < 0 OrElse referenceIndex < 0 Then Continue For
            .matched = -1
            If movingIndex = referenceIndex Then
                Dim sameDeclarationPhase As Long = GenericMoveAboveDeclarationPhase( _
                    translation.sourceUnit.declarations(movingIndex))
                If sameDeclarationPhase <> C2FB_MOVE_PHASE_TYPEDEF AndAlso _
                   sameDeclarationPhase <> C2FB_MOVE_PHASE_DECLARATION Then _
                    .failureReason = "both names are in one grouped type declaration"
                Continue For
            End If
            Dim movingPhase As Long = GenericMoveAboveDeclarationPhase( _
                translation.sourceUnit.declarations(movingIndex))
            Dim referencePhase As Long = GenericMoveAboveDeclarationPhase( _
                translation.sourceUnit.declarations(referenceIndex))
            If movingPhase = C2FB_MOVE_PHASE_INVALID OrElse _
               movingPhase <> referencePhase Then
                If movingPhase = C2FB_MOVE_PHASE_DECLARATION AndAlso _
                   referencePhase = C2FB_MOVE_PHASE_TYPEDEF AndAlso _
                   (GenericMoveAboveCanHoistPlainObject( _
                        translation, translation.sourceUnit.declarations(movingIndex), _
                        0, .movingName) <> 0 OrElse _
                    GenericMoveAboveIsSimpleBuiltinFunctionPrototype( _
                        translation, translation.sourceUnit.declarations(movingIndex), _
                        .movingName) <> 0) AndAlso _
                   GenericMoveAboveCanHoistPlainObject( _
                    translation, translation.sourceUnit.declarations(referenceIndex), _
                    -1, .referenceName) <> 0 Then
                    .hoisted = -1
                    Continue For
                End If
                .failureReason = "names belong to different output phases"
                Continue For
            End If
            MoveGenericDeclarationAbove( _
                translation.sourceUnit, movingIndex, referenceIndex)
            .applied = -1
        End With
    Next
End Sub

/' end of c2fb_generic_ordering.bi '/
