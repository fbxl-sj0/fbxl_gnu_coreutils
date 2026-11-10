/'
    Project: C2FB generic C policy
    ------------------------------

    File: c2fb_generic_policy.bi

    Purpose:

        Own generic C translation overrides and names independently of the CLI.

    Responsibilities:

        - Store and resolve type, symbol, string, array, include, and library overrides.
        - Track source filters, exclusions, and generated prefixes.
        - Store requested declaration moves and their application status.
        - Track declaration guard patterns and their matches.
        - Track selected macro expansion requests and their outcomes.
        - Track explicit integer-only macro assumptions and their matches.
        - Track selected incomplete record forward declarations.
        - Keep generic-header aliases and caller policy separate from parsing.
        - Apply generic C naming and string policies through the translation context.

    This file intentionally does NOT contain:

        - Command-line tokenization or compiler preprocessing.
        - C type syntax parsing, target mapping, or generated output formatting.
'/


Private Sub ResetGenericTypeOverridesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.typeOverrides(0 To 31)
    policy.typeOverrideCount = 0
End Sub

Private Sub AddGenericTypeOverrideInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourceName As String, ByVal freeBasicType As String, _
    ByVal isTypedefHint As Long = 0 _
)
    sourceName = Trim(sourceName)
    freeBasicType = Trim(freeBasicType)
    If sourceName = "" OrElse freeBasicType = "" OrElse _
       IsIdentifierStart(Asc(sourceName, 1)) = 0 Then _
        ReportError("type mapping must have the form CType=FreeBasicType")
    For position As Long = 2 To Len(sourceName)
        If IsIdentifierPart(Asc(sourceName, position)) = 0 Then _
            ReportError("C type mappings must use a single C identifier")
    Next
    Dim position As Long = 1
    While position <= Len(freeBasicType)
        While position <= Len(freeBasicType) AndAlso _
              IsSpaceByte(Asc(freeBasicType, position)) <> 0
            position += 1
        Wend
        If position > Len(freeBasicType) Then Exit While
        If IsIdentifierStart(Asc(freeBasicType, position)) = 0 Then _
            ReportError("mapped FreeBASIC type must contain identifier names")
        position += 1
        While position <= Len(freeBasicType) AndAlso _
              IsIdentifierPart(Asc(freeBasicType, position)) <> 0
            position += 1
        Wend
    Wend

    For overrideIndex As Long = 0 To policy.typeOverrideCount - 1
        If policy.typeOverrides(overrideIndex).sourceName = sourceName Then
            If isTypedefHint = 0 OrElse _
               policy.typeOverrides(overrideIndex).isTypedefHint <> 0 Then
                policy.typeOverrides(overrideIndex).freeBasicType = freeBasicType
                policy.typeOverrides(overrideIndex).isTypedefHint = isTypedefHint
            End If
            Exit Sub
        End If
    Next
    If policy.typeOverrideCount >= MAX_FUNCTIONS Then _
        ReportError("too many generic C type mappings")
    If policy.typeOverrideCount > UBound(policy.typeOverrides) Then _
        ReDim Preserve policy.typeOverrides(0 To UBound(policy.typeOverrides) * 2 + 1)
    policy.typeOverrides(policy.typeOverrideCount).sourceName = sourceName
    policy.typeOverrides(policy.typeOverrideCount).freeBasicType = freeBasicType
    policy.typeOverrides(policy.typeOverrideCount).isTypedefHint = isTypedefHint
    policy.typeOverrideCount += 1
End Sub

Private Function GenericTypeOverrideInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As String
    For overrideIndex As Long = 0 To policy.typeOverrideCount - 1
        If policy.typeOverrides(overrideIndex).sourceName = sourceName Then _
            Return policy.typeOverrides(overrideIndex).freeBasicType
    Next
    Return ""
End Function

Private Function GenericTypeOverrideIsTypedefHintInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    For overrideIndex As Long = 0 To policy.typeOverrideCount - 1
        If policy.typeOverrides(overrideIndex).sourceName = sourceName Then _
            Return policy.typeOverrides(overrideIndex).isTypedefHint
    Next
    Return 0
End Function

Private Function GenericTypeOverrideAlignmentInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    For overrideIndex As Long = 0 To policy.typeOverrideCount - 1
        If policy.typeOverrides(overrideIndex).sourceName = sourceName Then _
            Return policy.typeOverrides(overrideIndex).alignmentValue
    Next
    Return 0
End Function

Private Function GenericTypeOverrideAlignmentByFreeBasicTypeInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal freeBasicType As String _
) As Long
    For overrideIndex As Long = 0 To policy.typeOverrideCount - 1
        If LCase(policy.typeOverrides(overrideIndex).freeBasicType) = _
           LCase(freeBasicType) AndAlso _
           policy.typeOverrides(overrideIndex).alignmentValue > 0 Then _
            Return policy.typeOverrides(overrideIndex).alignmentValue
    Next
    Return 0
End Function

Private Sub ParseGenericTypeAlignmentArgumentInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal alignmentText As String _
)
    Dim equalsPosition As Long = InStr(alignmentText, "=")
    If equalsPosition <= 1 OrElse equalsPosition >= Len(alignmentText) Then _
        ReportError("type alignment must have the form CType=Bytes")

    Dim sourceName As String = Trim(Left(alignmentText, equalsPosition - 1))
    Dim valueText As String = Trim(Mid(alignmentText, equalsPosition + 1))
    Dim alignmentValue As Long = 0
    If sourceName = "" OrElse IsIdentifierStart(Asc(sourceName, 1)) = 0 OrElse _
       valueText = "" Then _
        ReportError("type alignment must have the form CType=Bytes")
    For position As Long = 2 To Len(sourceName)
        If IsIdentifierPart(Asc(sourceName, position)) = 0 Then _
            ReportError("type alignment must name one C type")
    Next
    For position As Long = 1 To Len(valueText)
        Dim digit As Long = Asc(valueText, position) - Asc("0")
        If digit < 0 OrElse digit > 9 Then _
            ReportError("type alignment must be a power of two from 1 through 16")
        alignmentValue = alignmentValue * 10 + digit
        If alignmentValue > 16 Then _
            ReportError("type alignment must be a power of two from 1 through 16")
    Next
    Select Case alignmentValue
    Case 1, 2, 4, 8, 16
    Case Else
        ReportError("type alignment must be a power of two from 1 through 16")
    End Select

    For overrideIndex As Long = 0 To policy.typeOverrideCount - 1
        If policy.typeOverrides(overrideIndex).sourceName = sourceName Then
            For otherIndex As Long = 0 To policy.typeOverrideCount - 1
                If otherIndex = overrideIndex OrElse _
                   LCase(policy.typeOverrides(otherIndex).freeBasicType) <> _
                       LCase(policy.typeOverrides(overrideIndex).freeBasicType) OrElse _
                   policy.typeOverrides(otherIndex).alignmentValue = 0 OrElse _
                   policy.typeOverrides(otherIndex).alignmentValue = alignmentValue Then _
                    Continue For
                ReportError("mapped FreeBASIC type has conflicting ABI alignments")
            Next
            policy.typeOverrides(overrideIndex).alignmentValue = alignmentValue
            Exit Sub
        End If
    Next
    ReportError("--type-alignment requires a preceding --type-map for " & sourceName)
End Sub

Private Sub AddGenericTypedefHintInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
)
    sourceName = Trim(sourceName)
    If sourceName = "" OrElse IsIdentifierStart(Asc(sourceName, 1)) = 0 Then _
        ReportError("--typedef-hint requires one C typedef name")
    For position As Long = 2 To Len(sourceName)
        If IsIdentifierPart(Asc(sourceName, position)) = 0 Then _
            ReportError("--typedef-hint requires one C typedef name")
    Next
    ' A caller-supplied mapping carries an explicit target type and must win
    ' regardless of whether the hint appears before or after that mapping.
    If GenericTypeOverrideInPolicy(policy, sourceName) = "" Then _
        AddGenericTypeOverrideInPolicy(policy, sourceName, sourceName, -1)
End Sub

Private Sub ResetGenericTypedefExpansionsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.typedefExpansions(0 To 31)
    policy.typedefExpansionCount = 0
End Sub

Private Sub AddGenericTypedefExpansionInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
)
    sourceName = Trim(sourceName)
    If sourceName = "" OrElse IsIdentifierStart(Asc(sourceName, 1)) = 0 Then _
        ReportError("--expand-type requires one C typedef name")
    For position As Long = 2 To Len(sourceName)
        If IsIdentifierPart(Asc(sourceName, position)) = 0 Then _
            ReportError("--expand-type requires one C typedef name")
    Next
    For expansionIndex As Long = 0 To policy.typedefExpansionCount - 1
        If policy.typedefExpansions(expansionIndex).sourceName = sourceName Then Exit Sub
    Next
    If policy.typedefExpansionCount >= MAX_FUNCTIONS Then _
        ReportError("too many --expand-type names")
    If policy.typedefExpansionCount > UBound(policy.typedefExpansions) Then _
        ReDim Preserve policy.typedefExpansions( _
            0 To UBound(policy.typedefExpansions) * 2 + 1)
    policy.typedefExpansions(policy.typedefExpansionCount).sourceName = sourceName
    policy.typedefExpansions(policy.typedefExpansionCount).matched = 0
    policy.typedefExpansionCount += 1
End Sub

Private Function GenericTypedefExpansionRequestedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    For expansionIndex As Long = 0 To policy.typedefExpansionCount - 1
        If policy.typedefExpansions(expansionIndex).sourceName = sourceName Then _
            Return -1
    Next
    Return 0
End Function

Private Sub ResetGenericMacroExpansionPatternsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.macroExpansionPatterns(0 To 15)
    policy.macroExpansionPatternCount = 0
End Sub

Private Sub AddGenericMacroExpansionPatternInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal namePattern As String, _
    ByVal isAutomatic As Long = 0 _
)
    namePattern = Trim(namePattern)
    If namePattern = "" OrElse _
       (IsIdentifierStart(Asc(namePattern, 1)) = 0 AndAlso _
        Asc(namePattern, 1) <> Asc("*") AndAlso _
        Asc(namePattern, 1) <> Asc("?")) Then _
        ReportError("--expand-macro requires a C macro name pattern")
    For position As Long = 2 To Len(namePattern)
        Dim currentByte As Long = Asc(namePattern, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("--expand-macro accepts one macro name pattern using * or ?")
    Next
    For patternIndex As Long = 0 To policy.macroExpansionPatternCount - 1
        If policy.macroExpansionPatterns(patternIndex).pattern = namePattern Then
            If isAutomatic = 0 Then _
                policy.macroExpansionPatterns(patternIndex).automatic = 0
            Exit Sub
        End If
    Next
    If policy.macroExpansionPatternCount >= MAX_FUNCTIONS Then _
        ReportError("too many --expand-macro patterns")
    If policy.macroExpansionPatternCount > _
       UBound(policy.macroExpansionPatterns) Then _
        ReDim Preserve policy.macroExpansionPatterns( _
            0 To UBound(policy.macroExpansionPatterns) * 2 + 1)
    policy.macroExpansionPatterns( _
        policy.macroExpansionPatternCount).pattern = namePattern
    policy.macroExpansionPatterns( _
        policy.macroExpansionPatternCount).matched = 0
    policy.macroExpansionPatterns( _
        policy.macroExpansionPatternCount).expandedCount = 0
    policy.macroExpansionPatterns( _
        policy.macroExpansionPatternCount).unsupportedCount = 0
    policy.macroExpansionPatterns( _
        policy.macroExpansionPatternCount).excludedCount = 0
    policy.macroExpansionPatterns( _
        policy.macroExpansionPatternCount).automatic = _
            CInt(isAutomatic <> 0) * -1
    policy.macroExpansionPatternCount += 1
End Sub

Private Sub ResetGenericMacroInDefineExpansionPatternsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.macroInDefineExpansionPatterns(0 To 15)
    policy.macroInDefineExpansionPatternCount = 0
End Sub

Private Sub AddGenericMacroInDefineExpansionPatternInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal namePattern As String _
)
    namePattern = Trim(namePattern)
    If namePattern = "" OrElse _
       (IsIdentifierStart(Asc(namePattern, 1)) = 0 AndAlso _
        Asc(namePattern, 1) <> Asc("*") AndAlso _
        Asc(namePattern, 1) <> Asc("?")) Then _
        ReportError("--expand-in-define requires a C macro name pattern")
    For position As Long = 2 To Len(namePattern)
        Dim currentByte As Long = Asc(namePattern, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("--expand-in-define accepts one macro name pattern using * or ?")
    Next
    For patternIndex As Long = 0 To policy.macroInDefineExpansionPatternCount - 1
        If policy.macroInDefineExpansionPatterns(patternIndex).pattern = namePattern Then _
            Exit Sub
    Next
    If policy.macroInDefineExpansionPatternCount >= MAX_FUNCTIONS Then _
        ReportError("too many --expand-in-define patterns")
    If policy.macroInDefineExpansionPatternCount > _
       UBound(policy.macroInDefineExpansionPatterns) Then _
        ReDim Preserve policy.macroInDefineExpansionPatterns( _
            0 To UBound(policy.macroInDefineExpansionPatterns) * 2 + 1)
    With policy.macroInDefineExpansionPatterns( _
        policy.macroInDefineExpansionPatternCount)
        .pattern = namePattern
        .matched = 0
        .expandedCount = 0
        .unsupportedCount = 0
        .excludedCount = 0
    End With
    policy.macroInDefineExpansionPatternCount += 1
End Sub

Private Sub ResetGenericMacroNoExpansionPatternsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.macroNoExpansionPatterns(0 To 15)
    policy.macroNoExpansionPatternCount = 0
End Sub

Private Sub AddGenericMacroNoExpansionPatternInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal namePattern As String _
)
    namePattern = Trim(namePattern)
    If namePattern = "" OrElse _
       (IsIdentifierStart(Asc(namePattern, 1)) = 0 AndAlso _
        Asc(namePattern, 1) <> Asc("*") AndAlso _
        Asc(namePattern, 1) <> Asc("?")) Then _
        ReportError("--no-expand-macro requires a C macro name pattern")
    For position As Long = 2 To Len(namePattern)
        Dim currentByte As Long = Asc(namePattern, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("--no-expand-macro accepts one macro name pattern using * or ?")
    Next
    For patternIndex As Long = 0 To policy.macroNoExpansionPatternCount - 1
        If policy.macroNoExpansionPatterns(patternIndex).pattern = namePattern Then _
            Exit Sub
    Next
    If policy.macroNoExpansionPatternCount >= MAX_FUNCTIONS Then _
        ReportError("too many --no-expand-macro patterns")
    If policy.macroNoExpansionPatternCount > _
       UBound(policy.macroNoExpansionPatterns) Then _
        ReDim Preserve policy.macroNoExpansionPatterns( _
            0 To UBound(policy.macroNoExpansionPatterns) * 2 + 1)
    policy.macroNoExpansionPatterns( _
        policy.macroNoExpansionPatternCount).pattern = namePattern
    policy.macroNoExpansionPatterns( _
        policy.macroNoExpansionPatternCount).matched = 0
    policy.macroNoExpansionPatterns( _
        policy.macroNoExpansionPatternCount).expandedCount = 0
    policy.macroNoExpansionPatterns( _
        policy.macroNoExpansionPatternCount).unsupportedCount = 0
    policy.macroNoExpansionPatterns( _
        policy.macroNoExpansionPatternCount).excludedCount = 0
    policy.macroNoExpansionPatternCount += 1
End Sub

Private Function GenericMacroNoExpansionInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    Dim matched As Long = 0
    For patternIndex As Long = 0 To policy.macroNoExpansionPatternCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.macroNoExpansionPatterns(patternIndex).pattern) <> 0 Then
            policy.macroNoExpansionPatterns(patternIndex).matched = -1
            matched = -1
        End If
    Next
    Return matched
End Function

Private Sub ResetGenericForwardDeclarationPatternsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.forwardDeclarationPatterns(0 To 15)
    policy.forwardDeclarationPatternCount = 0
End Sub

Private Sub AddGenericForwardDeclarationPatternInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal namePattern As String _
)
    namePattern = Trim(namePattern)
    If namePattern = "" OrElse _
       (IsIdentifierStart(Asc(namePattern, 1)) = 0 AndAlso _
        Asc(namePattern, 1) <> Asc("*") AndAlso _
        Asc(namePattern, 1) <> Asc("?")) Then _
        ReportError("--forward-decl requires a C type name pattern")
    For position As Long = 2 To Len(namePattern)
        Dim currentByte As Long = Asc(namePattern, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("--forward-decl accepts one C type name pattern using * or ?")
    Next
    For patternIndex As Long = 0 To policy.forwardDeclarationPatternCount - 1
        If policy.forwardDeclarationPatterns(patternIndex).pattern = namePattern Then _
            Exit Sub
    Next
    If policy.forwardDeclarationPatternCount >= MAX_FUNCTIONS Then _
        ReportError("too many --forward-decl patterns")
    If policy.forwardDeclarationPatternCount > _
       UBound(policy.forwardDeclarationPatterns) Then _
        ReDim Preserve policy.forwardDeclarationPatterns( _
            0 To UBound(policy.forwardDeclarationPatterns) * 2 + 1)
    policy.forwardDeclarationPatterns( _
        policy.forwardDeclarationPatternCount).pattern = namePattern
    policy.forwardDeclarationPatterns( _
        policy.forwardDeclarationPatternCount).matched = 0
    policy.forwardDeclarationPatternCount += 1
End Sub

Private Function MarkGenericForwardDeclarationRequestedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal tagName As String, ByVal aliasName As String _
) As Long
    Dim matched As Long = 0
    For patternIndex As Long = 0 To policy.forwardDeclarationPatternCount - 1
        If (tagName <> "" AndAlso GenericIdentifierMatchesPattern( _
                tagName, policy.forwardDeclarationPatterns(patternIndex).pattern) <> 0) OrElse _
           (aliasName <> "" AndAlso GenericIdentifierMatchesPattern( _
                aliasName, policy.forwardDeclarationPatterns(patternIndex).pattern) <> 0) Then
            policy.forwardDeclarationPatterns(patternIndex).matched = -1
            matched = -1
        End If
    Next
    Return matched
End Function

Private Function GenericMacroExpansionRequestedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    For patternIndex As Long = 0 To policy.macroExpansionPatternCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.macroExpansionPatterns(patternIndex).pattern) <> 0 Then _
            Return -1
    Next
    Return 0
End Function

Private Function GenericMacroInDefineExpansionRequestedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    For patternIndex As Long = 0 To policy.macroInDefineExpansionPatternCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.macroInDefineExpansionPatterns(patternIndex).pattern) <> 0 Then _
            Return -1
    Next
    Return 0
End Function

Private Sub MarkGenericMacroExpansionInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String, _
    ByVal wasExpanded As Long _
)
    For patternIndex As Long = 0 To policy.macroExpansionPatternCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.macroExpansionPatterns(patternIndex).pattern) = 0 Then _
            Continue For
        policy.macroExpansionPatterns(patternIndex).matched = -1
        If wasExpanded > 0 Then
            policy.macroExpansionPatterns(patternIndex).expandedCount += 1
        ElseIf wasExpanded < 0 Then
            policy.macroExpansionPatterns(patternIndex).excludedCount += 1
        Else
            policy.macroExpansionPatterns(patternIndex).unsupportedCount += 1
        End If
    Next
End Sub

Private Sub MarkGenericMacroInDefineExpansionInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String, _
    ByVal wasExpanded As Long _
)
    For patternIndex As Long = 0 To policy.macroInDefineExpansionPatternCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, _
            policy.macroInDefineExpansionPatterns(patternIndex).pattern) = 0 Then _
            Continue For
        policy.macroInDefineExpansionPatterns(patternIndex).matched = -1
        If wasExpanded > 0 Then
            policy.macroInDefineExpansionPatterns(patternIndex).expandedCount += 1
        ElseIf wasExpanded < 0 Then
            policy.macroInDefineExpansionPatterns(patternIndex).excludedCount += 1
        Else
            policy.macroInDefineExpansionPatterns(patternIndex).unsupportedCount += 1
        End If
    Next
End Sub

Private Sub MarkGenericTypedefExpansionMatchedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
)
    For expansionIndex As Long = 0 To policy.typedefExpansionCount - 1
        If policy.typedefExpansions(expansionIndex).sourceName = sourceName Then
            policy.typedefExpansions(expansionIndex).matched = -1
            Exit Sub
        End If
    Next
End Sub

Private Sub ParseGenericTypeMapArgumentInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal mapText As String _
)
    Dim equalsPosition As Long = InStr(mapText, "=")
    If equalsPosition <= 1 OrElse equalsPosition >= Len(mapText) Then _
        ReportError("type mapping must have the form CType=FreeBasicType")
    AddGenericTypeOverrideInPolicy(policy, _
        Left(mapText, equalsPosition - 1), Mid(mapText, equalsPosition + 1))
End Sub

Private Sub ResetGenericSymbolRenamesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.symbolRenames(0 To 31)
    policy.symbolRenameCount = 0
End Sub

Private Sub AddGenericSymbolRenameInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourceName As String, ByVal freeBasicName As String, _
    ByVal renameNamespace As C2fbSymbolRenameNamespace = _
        C2FB_SYMBOL_RENAME_GENERAL _
)
    sourceName = Trim(sourceName)
    freeBasicName = Trim(freeBasicName)
    If sourceName = "" OrElse freeBasicName = "" OrElse _
       IsIdentifierStart(Asc(sourceName, 1)) = 0 OrElse _
       IsIdentifierStart(Asc(freeBasicName, 1)) = 0 Then _
        ReportError("symbol rename must have the form CName=FbName")
    For position As Long = 2 To Len(sourceName)
        If IsIdentifierPart(Asc(sourceName, position)) = 0 Then _
            ReportError("renamed C symbols must use a single identifier")
    Next
    For position As Long = 2 To Len(freeBasicName)
        If IsIdentifierPart(Asc(freeBasicName, position)) = 0 Then _
            ReportError("renamed FreeBASIC symbols must use a single identifier")
    Next

    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        If policy.symbolRenames(renameIndex).sourceName = sourceName AndAlso _
           policy.symbolRenames(renameIndex).renameNamespace = renameNamespace Then
            policy.symbolRenames(renameIndex).freeBasicName = freeBasicName
            policy.symbolRenames(renameIndex).matched = 0
            Exit Sub
        End If
    Next
    If policy.symbolRenameCount >= MAX_FUNCTIONS Then _
        ReportError("too many generic C symbol renames")
    If policy.symbolRenameCount > UBound(policy.symbolRenames) Then _
        ReDim Preserve policy.symbolRenames(0 To UBound(policy.symbolRenames) * 2 + 1)
    policy.symbolRenames(policy.symbolRenameCount).sourceName = sourceName
    policy.symbolRenames(policy.symbolRenameCount).freeBasicName = freeBasicName
    policy.symbolRenames(policy.symbolRenameCount).renameNamespace = renameNamespace
    policy.symbolRenames(policy.symbolRenameCount).matched = 0
    policy.symbolRenameCount += 1
End Sub

Private Function GenericSymbolRenameInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As String
    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        If policy.symbolRenames(renameIndex).sourceName = sourceName AndAlso _
           policy.symbolRenames(renameIndex).renameNamespace = _
               C2FB_SYMBOL_RENAME_GENERAL Then
            policy.symbolRenames(renameIndex).matched = -1
            Return policy.symbolRenames(renameIndex).freeBasicName
        End If
    Next
    Return ""
End Function

Private Function GenericStaticObjectReuseInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As String
    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        With policy.symbolRenames(renameIndex)
            If .sourceName = sourceName AndAlso _
               .renameNamespace = C2FB_SYMBOL_RENAME_STATIC_OBJECT_REUSE Then
                .matched = -1
                Return .freeBasicName
            End If
        End With
    Next
    Return ""
End Function

Private Function GenericStaticObjectLayoutInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String, _
    ByRef freeBasicType As String, ByRef arrayCount As Long _
) As Long
    freeBasicType = ""
    arrayCount = 0
    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        With policy.symbolRenames(renameIndex)
            If .sourceName = sourceName AndAlso _
               .renameNamespace = C2FB_SYMBOL_RENAME_STATIC_OBJECT_REUSE Then
                .matched = -1
                freeBasicType = .reusedStaticFreeBasicType
                arrayCount = .reusedStaticArrayCount
                Return CInt(freeBasicType <> "" AndAlso arrayCount > 0) * -1
            End If
        End With
    Next
    Return 0
End Function

Private Function GenericTypeRenameInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String, _
    ByVal renameNamespace As C2fbSymbolRenameNamespace _
) As String
    Dim generalRenameIndex As Long = -1
    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        With policy.symbolRenames(renameIndex)
            If .sourceName <> sourceName Then Continue For
            If .renameNamespace = renameNamespace Then
                .matched = -1
                Return .freeBasicName
            ElseIf .renameNamespace = C2FB_SYMBOL_RENAME_GENERAL Then
                generalRenameIndex = renameIndex
            End If
        End With
    Next
    If generalRenameIndex >= 0 Then
        policy.symbolRenames(generalRenameIndex).matched = -1
        Return policy.symbolRenames(generalRenameIndex).freeBasicName
    End If
    Return ""
End Function

Private Function GenericProcedureRenameInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As String
    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        With policy.symbolRenames(renameIndex)
            If .sourceName = sourceName AndAlso _
               .renameNamespace = C2FB_SYMBOL_RENAME_PROCEDURE Then
                .matched = -1
                Return .freeBasicName
            End If
        End With
    Next
    Dim generalName As String = GenericSymbolRenameInPolicy(policy, sourceName)
    If generalName <> "" Then Return generalName
    If policy.procedureNamePrefix <> "" Then
        policy.procedureNamePrefixMatched = -1
        Return policy.procedureNamePrefix & sourceName
    End If
    Return ""
End Function

Private Function GenericMacroRenameInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As String
    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        With policy.symbolRenames(renameIndex)
            If .sourceName = sourceName AndAlso _
               .renameNamespace = C2FB_SYMBOL_RENAME_DEFINE Then
                .matched = -1
                Return .freeBasicName
            End If
        End With
    Next
    Return GenericSymbolRenameInPolicy(policy, sourceName)
End Function

Private Function GenericMacroParameterRenameInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As String
    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        With policy.symbolRenames(renameIndex)
            If .sourceName = sourceName AndAlso _
               .renameNamespace = C2FB_SYMBOL_RENAME_MACRO_PARAMETER Then
                .matched = -1
                Return .freeBasicName
            End If
        End With
    Next
    Return ""
End Function

' Keep this list aligned with the non-QB keyword table in FBC's
' compiler/symbols/symb-keyword.bas. C2FB emits headers in the normal FB dialect.
Private Const C2FB_FREEBASIC_MACRO_KEYWORDS As String = _
    "|AND|OR|ANDALSO|ORELSE|XOR|EQV|IMP|NOT|MOD|SHL|SHR|NEW|DELETE|REM|DIM|ABS|SGN|FIX|" & _
    "FRAC|INT|STATIC|SHARED|BOOLEAN|BYTE|UBYTE|SHORT|USHORT|INTEGER|UINTEGER|LONG|ULONG|" & _
    "LONGINT|ULONGINT|SINGLE|DOUBLE|STRING|ZSTRING|USTRING|UCHR|WSTRING|UNSIGNED|ANY|PTR|" & _
    "POINTER|TYPEOF|WHILE|UNTIL|WEND|CONTINUE|CBOOL|CBYTE|CSHORT|CINT|CLNG|CLNGINT|" & _
    "CUBYTE|CUSHORT|CUINT|CULNG|CULNGINT|CSNG|CDBL|CSIGN|CUNSG|CPTR|CAST|CALL|BYVAL|" & _
    "BYREF|AS|DECLARE|GOTO|CONST|FOR|STEP|NEXT|TO|TYPE|UNION|END|SUB|FUNCTION|CDECL|" & _
    "STDCALL|__THISCALL|__FASTCALL|PASCAL|ALIAS|LIB|LET|EXIT|DO|LOOP|RETURN|IF|THEN|ELSE|" & _
    "ELSEIF|ENDIF|SELECT|CASE|IS|USING|LEN|PEEK|POKE|SWAP|COMMON|ENUM|ASM|EXTERN|WITH|" & _
    "SCOPE|PUBLIC|PRIVATE|PROTECTED|PROCPTR|NAMESPACE|EXPORT|IMPORT|OVERLOAD|CONSTRUCTOR|" & _
    "DESTRUCTOR|OPERATOR|PROPERTY|CLASS|EXTENDS|IMPLEMENTS|BASE|VIRTUAL|ABSTRACT|VAR|IIF|" & _
    "VA_FIRST|DATA|FIELD|LOCAL|DEFINED|SIZEOF|STRPTR|VARPTR|DYNAMIC|INCLUDE|GOSUB|" & _
    "DEFBYTE|DEFUBYTE|DEFSHORT|DEFUSHORT|DEFINT|DEFUINT|DEFLNG|DEFULNG|DEFLONGINT|" & _
    "DEFULONGINT|DEFSNG|DEFDBL|DEFSTR|OPTION|EXPLICIT|SADD|ON|ERROR|SIN|ASIN|COS|ACOS|" & _
    "TAN|ATN|SQR|LOG|EXP|ATAN2|RESUME|ERR|REDIM|ERASE|LBOUND|UBOUND|STR|CVD|CVS|CVI|CVL|" & _
    "CVSHORT|CVLONGINT|MKD|MKS|MKI|MKL|MKSHORT|MKLONGINT|__FB_SERIALIZE|__FB_DESERIALIZE|" & _
    "WSTR|MID|INSTR|INSTRREV|TRIM|RTRIM|LTRIM|LCASE|UCASE|RESTORE|READ|PRINT|LPRINT|OPEN|" & _
    "CLOSE|SEEK|PUT|GET|ACCESS|WRITE|LOCK|INPUT|WINPUT|OUTPUT|BINARY|RANDOM|APPEND|" & _
    "ENCODING|NAME|WIDTH|COLOR|PRESERVE|SPC|TAB|LINE|VIEW|UNLOCK|CHR|WCHR|ASC|LSET|RSET|" & _
    "PSET|PRESET|POINT|CIRCLE|WINDOW|PALETTE|SCREEN|PAINT|DRAW|IMAGECREATE|THREADCALL|" & _
    "TCP|MUSIC|SFX|MIDI|DEVICE|CAPTURE|CVA_START|CVA_END|CVA_ARG|CVA_COPY|FALSE|TRUE|NULL|"

Private Function C2fbFreeBasicIdentifierIsKeyword( _
    ByVal identifier As String _
) As Long
    If identifier = "" Then Return 0
    Return CInt(InStr( _
        C2FB_FREEBASIC_MACRO_KEYWORDS, "|" & UCase(identifier) & "|") <> 0)
End Function

' FreeBASIC accepts many keywords as ordinary Type fields, including TYPE.
' These operator and declaration tokens are rejected by the field parser and
' need a suffix when C2FB emits a C record member with the same name. The
' lowercase C field `unicode` also collides with the case-insensitive UNICODE
' preprocessor define used by Windows target profiles.
Private Function C2fbFreeBasicFieldIdentifierNeedsEscape( _
    ByVal identifier As String _
) As Long
    Select Case LCase(identifier)
    ' RGB is a function name, so FBC reads an array field as a call.
    Case "rgb"
        Return -1
    Case "and", "or", "andalso", "orelse", "xor", "eqv", "imp", "not", _
         "mod", "shl", "shr", "new", "delete", "rem", "dim", "static", _
         "as", "declare", "const", "enum", "public", "private", _
         "protected", "redim", "unicode"
        Return -1
    Case Else
        Return 0
    End Select
End Function

Private Function C2fbMacroParameterIsKeyword(ByVal parameterName As String) As Long
    Return C2fbFreeBasicIdentifierIsKeyword(parameterName)
End Function

Private Sub ApplyGenericMacroParameterRenamesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal macroBody As String = "" _
)
    Dim sourceParameterNames As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(sourceParameterNames)
    For parameterIndex As Long = 0 To parameterCount - 1
        If AddC2fbStringIndexMapEntry( _
            sourceParameterNames, parameterNames(parameterIndex), _
            parameterIndex) = 0 Then _
            ReportError("macro parameters exceed the collision index limit")
    Next

    Dim bodyIdentifierNames As C2fbNameSetModel
    ResetC2fbNameSet(bodyIdentifierNames)
    Dim bodyTokens() As String
    Dim bodyTokenCount As Long
    If macroBody <> "" AndAlso TokenizeCPreprocessorReplacement( _
        macroBody, bodyTokens(), bodyTokenCount) <> 0 Then
        For tokenIndex As Long = 0 To bodyTokenCount - 1
            If IsIdentifierToken(bodyTokens(tokenIndex)) = 0 OrElse _
               C2fbStringIndexMapLookup( _
                   sourceParameterNames, bodyTokens(tokenIndex)) >= 0 Then _
                Continue For
            If AddC2fbNameSet(bodyIdentifierNames, bodyTokens(tokenIndex)) = 0 Then _
                ReportError("macro body identifiers exceed the collision index limit")
        Next
    End If

    For parameterIndex As Long = 0 To parameterCount - 1
        Dim renamedParameter As String = GenericMacroParameterRenameInPolicy( _
            policy, parameterNames(parameterIndex))
        If renamedParameter <> "" Then _
            freeParameterNames(parameterIndex) = renamedParameter
        renamedParameter = freeParameterNames(parameterIndex)
        Dim nameConflict As Long
        Do
            nameConflict = 0
            If C2fbMacroParameterIsKeyword(renamedParameter) <> 0 OrElse _
               C2fbNameSetContains( _
                   bodyIdentifierNames, renamedParameter) <> 0 Then
                renamedParameter &= "_"
                nameConflict = -1
            End If
            For priorIndex As Long = 0 To parameterIndex - 1
                If nameConflict = 0 AndAlso _
                   LCase(freeParameterNames(priorIndex)) = LCase(renamedParameter) Then
                    renamedParameter &= "_"
                    nameConflict = -1
                    Exit For
                End If
            Next
        Loop While nameConflict <> 0
        freeParameterNames(parameterIndex) = renamedParameter
    Next
End Sub

Private Sub ResetGenericStringOverridesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.stringOverrides(0 To 31)
    policy.stringOverrideCount = 0
End Sub

Private Sub AddGenericStringOverrideInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourceName As String, ByVal mode As Long _
)
    sourceName = Trim(sourceName)
    If sourceName = "" OrElse _
       (IsIdentifierStart(Asc(sourceName, 1)) = 0 AndAlso _
        Asc(sourceName, 1) <> Asc("*") AndAlso Asc(sourceName, 1) <> Asc("?")) Then _
        ReportError("string override requires a C identifier or wildcard pattern")
    For position As Long = 2 To Len(sourceName)
        Dim currentByte As Long = Asc(sourceName, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") AndAlso _
           currentByte <> Asc(".") Then _
            ReportError("string overrides accept a C name pattern using ., *, or ?")
    Next
    Dim duplicateIndex As Long = -1
    For overrideIndex As Long = 0 To policy.stringOverrideCount - 1
        If policy.stringOverrides(overrideIndex).sourceName = sourceName Then
            duplicateIndex = overrideIndex
            Exit For
        End If
    Next
    If duplicateIndex >= 0 Then
        For moveIndex As Long = duplicateIndex To policy.stringOverrideCount - 2
            policy.stringOverrides(moveIndex) = policy.stringOverrides(moveIndex + 1)
        Next
        policy.stringOverrideCount -= 1
    End If
    If policy.stringOverrideCount >= MAX_FUNCTIONS Then _
        ReportError("too many generic string overrides")
    If policy.stringOverrideCount > UBound(policy.stringOverrides) Then _
        ReDim Preserve policy.stringOverrides(0 To UBound(policy.stringOverrides) * 2 + 1)
    policy.stringOverrides(policy.stringOverrideCount).sourceName = sourceName
    policy.stringOverrides(policy.stringOverrideCount).mode = mode
    policy.stringOverrideCount += 1
End Sub

Private Function GenericStringOverrideModeInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    For overrideIndex As Long = policy.stringOverrideCount - 1 To 0 Step -1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.stringOverrides(overrideIndex).sourceName) <> 0 Then _
            Return policy.stringOverrides(overrideIndex).mode
    Next
    Return 0
End Function

Private Function GenericStringOverrideModeForFieldInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal ownerTag As String, ByVal ownerAlias As String, _
    ByVal fieldName As String, ByVal parameterIndex As Long = -1 _
) As Long
    Dim taggedName As String = ownerTag
    Dim aliasedName As String = ownerAlias
    If taggedName <> "" Then taggedName &= "."
    If aliasedName <> "" Then aliasedName &= "."
    For overrideIndex As Long = policy.stringOverrideCount - 1 To 0 Step -1
        Dim pattern As String = policy.stringOverrides(overrideIndex).sourceName
        If GenericIdentifierMatchesPattern(fieldName, pattern) <> 0 OrElse _
           (ownerTag <> "" AndAlso _
            GenericIdentifierMatchesPattern(taggedName & fieldName, pattern) <> 0) OrElse _
           (ownerTag <> "" AndAlso parameterIndex >= 0 AndAlso _
            GenericIdentifierMatchesPattern( _
                ownerTag & "." & Trim(Str(parameterIndex)), pattern) <> 0) OrElse _
           (ownerAlias <> "" AndAlso ownerAlias <> ownerTag AndAlso _
            (GenericIdentifierMatchesPattern(aliasedName & fieldName, pattern) <> 0 OrElse _
             (parameterIndex >= 0 AndAlso GenericIdentifierMatchesPattern( _
                ownerAlias & "." & Trim(Str(parameterIndex)), pattern) <> 0))) Then _
            Return policy.stringOverrides(overrideIndex).mode
    Next
    Return 0
End Function

Private Sub ResetGenericArraySizeOverridesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.arraySizeOverrides(0 To 31)
    policy.arraySizeOverrideCount = 0
End Sub

Private Function EvaluateGenericArraySizeHint( _
    ByVal boundExpression As String, ByRef arrayCount As Long _
) As Long
    If EvaluateSimpleArrayBound( _
        boundExpression, arrayCount, MAX_GENERIC_ARRAY_COUNT) <> 0 Then _
        Return -1

    boundExpression = Trim(boundExpression)
    If LCase(Left(boundExpression, 4)) <> "len(" OrElse _
       Right(boundExpression, 1) <> ")" Then Return 0
    Dim stringLiteral As String = Trim(Mid( _
        boundExpression, 5, Len(boundExpression) - 5))
    If Len(stringLiteral) < 2 OrElse _
       Asc(stringLiteral, 1) <> Asc(Chr(34)) OrElse _
       Asc(stringLiteral, Len(stringLiteral)) <> Asc(Chr(34)) Then Return 0

    Dim literalLength As Long = 0
    Dim position As Long = 2
    While position < Len(stringLiteral)
        Dim currentByte As Long = Asc(stringLiteral, position)
        If currentByte = Asc(Chr(34)) Then
            If position + 1 >= Len(stringLiteral) OrElse _
               Asc(stringLiteral, position + 1) <> Asc(Chr(34)) Then Return 0
            position += 2
        Else
            If currentByte = 0 OrElse currentByte = 10 OrElse currentByte = 13 Then _
                Return 0
            position += 1
        End If
        literalLength += 1
        If literalLength > MAX_GENERIC_ARRAY_COUNT Then Return 0
    Wend
    If literalLength <= 0 Then Return 0
    arrayCount = literalLength
    Return -1
End Function

Private Sub AddGenericArraySizeOverrideInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourceName As String, ByVal boundExpression As String _
)
    sourceName = Trim(sourceName)
    boundExpression = Trim(boundExpression)
    Dim separatorPosition As Long = InStr(sourceName, ".")
    If separatorPosition <> 0 Then
        If separatorPosition = 1 OrElse separatorPosition = Len(sourceName) OrElse _
           InStr(separatorPosition + 1, sourceName, ".") <> 0 Then _
            ReportError("qualified array-size hints must use CRecord.field form")
        Dim recordName As String = Left(sourceName, separatorPosition - 1)
        Dim fieldName As String = Mid(sourceName, separatorPosition + 1)
        If IsIdentifierStart(Asc(recordName, 1)) = 0 OrElse _
           IsIdentifierStart(Asc(fieldName, 1)) = 0 Then _
            ReportError("qualified array-size hints must use CRecord.field form")
        For position As Long = 2 To Len(recordName)
            If IsIdentifierPart(Asc(recordName, position)) = 0 Then _
                ReportError("qualified array-size hints must use CRecord.field form")
        Next
        For position As Long = 2 To Len(fieldName)
            If IsIdentifierPart(Asc(fieldName, position)) = 0 Then _
                ReportError("qualified array-size hints must use CRecord.field form")
        Next
    Else
        If sourceName = "" OrElse IsIdentifierStart(Asc(sourceName, 1)) = 0 Then _
            ReportError("array-size hint requires a C declaration identifier")
        For position As Long = 2 To Len(sourceName)
            If IsIdentifierPart(Asc(sourceName, position)) = 0 Then _
                ReportError("array-size hints must use one C identifier or CRecord.field")
        Next
    End If

    Dim arrayCount As Long
    If EvaluateGenericArraySizeHint(boundExpression, arrayCount) = 0 Then _
        ReportError("array-size hint must be an integer constant or Len(string literal) " & _
                    "expression from 1 to " & Trim(Str(MAX_GENERIC_ARRAY_COUNT)))
    For overrideIndex As Long = 0 To policy.arraySizeOverrideCount - 1
        If policy.arraySizeOverrides(overrideIndex).sourceName = sourceName Then
            policy.arraySizeOverrides(overrideIndex).arrayCount = arrayCount
            policy.arraySizeOverrides(overrideIndex).applied = 0
            Exit Sub
        End If
    Next
    If policy.arraySizeOverrideCount >= MAX_FUNCTIONS Then _
        ReportError("too many generic array-size hints")
    If policy.arraySizeOverrideCount > UBound(policy.arraySizeOverrides) Then _
        ReDim Preserve policy.arraySizeOverrides( _
            0 To UBound(policy.arraySizeOverrides) * 2 + 1)
    With policy.arraySizeOverrides(policy.arraySizeOverrideCount)
        .sourceName = sourceName
        .arrayCount = arrayCount
        .applied = 0
    End With
    policy.arraySizeOverrideCount += 1
End Sub

Private Sub ParseGenericArraySizeArgumentInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal hintText As String _
)
    Dim equalsPosition As Long = InStr(hintText, "=")
    If equalsPosition <= 1 OrElse equalsPosition >= Len(hintText) Then _
        ReportError("array-size hint must have the form CName[.field]=Count")
    AddGenericArraySizeOverrideInPolicy(policy, _
        Left(hintText, equalsPosition - 1), Mid(hintText, equalsPosition + 1))
End Sub

Private Function UseGenericArraySizeOverrideInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String, _
    ByVal ownerTag As String = "", ByVal ownerAlias As String = "" _
) As Long
    If ownerTag <> "" Then
        Dim qualifiedTagName As String = ownerTag & "." & sourceName
        For overrideIndex As Long = 0 To policy.arraySizeOverrideCount - 1
            If policy.arraySizeOverrides(overrideIndex).sourceName = qualifiedTagName Then
                policy.arraySizeOverrides(overrideIndex).applied = -1
                Return policy.arraySizeOverrides(overrideIndex).arrayCount
            End If
        Next
    End If
    If ownerAlias <> "" AndAlso ownerAlias <> ownerTag Then
        Dim qualifiedAliasName As String = ownerAlias & "." & sourceName
        For overrideIndex As Long = 0 To policy.arraySizeOverrideCount - 1
            If policy.arraySizeOverrides(overrideIndex).sourceName = qualifiedAliasName Then
                policy.arraySizeOverrides(overrideIndex).applied = -1
                Return policy.arraySizeOverrides(overrideIndex).arrayCount
            End If
        Next
    End If
    For overrideIndex As Long = 0 To policy.arraySizeOverrideCount - 1
        If policy.arraySizeOverrides(overrideIndex).sourceName = sourceName Then
            policy.arraySizeOverrides(overrideIndex).applied = -1
            Return policy.arraySizeOverrides(overrideIndex).arrayCount
        End If
    Next
    Return 0
End Function

Private Sub ResetGenericFreeBasicIncludesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.freeBasicIncludes(0 To 15)
    policy.freeBasicIncludeCount = 0
End Sub

Private Sub AddGenericFreeBasicIncludeInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal includePath As String _
)
    includePath = Trim(includePath)
    If includePath = "" Then ReportError("--fb-include requires a FreeBASIC include path")
    For position As Long = 1 To Len(includePath)
        Dim currentByte As Long = Asc(includePath, position)
        If currentByte < 32 OrElse _
           currentByte = Asc(Chr(34)) Then _
            ReportError("--fb-include paths cannot contain quotes or control characters")
    Next
    For includeIndex As Long = 0 To policy.freeBasicIncludeCount - 1
        If policy.freeBasicIncludes(includeIndex) = includePath Then Exit Sub
    Next
    If policy.freeBasicIncludeCount >= MAX_FUNCTIONS Then _
        ReportError("too many --fb-include paths")
    If policy.freeBasicIncludeCount > UBound(policy.freeBasicIncludes) Then _
        ReDim Preserve policy.freeBasicIncludes( _
            0 To UBound(policy.freeBasicIncludes) * 2 + 1)
    policy.freeBasicIncludes(policy.freeBasicIncludeCount) = includePath
    policy.freeBasicIncludeCount += 1
End Sub

Private Sub ResetGenericPreservedIncludesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.preservedIncludes(0 To 15)
    policy.preservedIncludeCount = 0
End Sub

Private Sub ResetGenericIncludeRemovalsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.includeRemovals(0 To 15)
    policy.includeRemovalCount = 0
End Sub

Private Sub AddGenericIncludeRemovalInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal cHeaderName As String _
)
    cHeaderName = Trim(cHeaderName)
    If Len(cHeaderName) >= 2 AndAlso _
       ((Left(cHeaderName, 1) = Chr(34) AndAlso Right(cHeaderName, 1) = Chr(34)) OrElse _
        (Left(cHeaderName, 1) = "<" AndAlso Right(cHeaderName, 1) = ">")) Then _
        cHeaderName = Mid(cHeaderName, 2, Len(cHeaderName) - 2)
    If cHeaderName = "" Then ReportError("-removeinclude requires a C header filename")
    For position As Long = 1 To Len(cHeaderName)
        Dim currentByte As Long = Asc(cHeaderName, position)
        If currentByte < 32 OrElse currentByte = 127 Then _
            ReportError("-removeinclude filenames cannot contain control characters")
        If currentByte = Asc(Chr(92)) Then Mid(cHeaderName, position, 1) = "/"
    Next
#if defined(__FB_WIN32__)
    cHeaderName = LCase(cHeaderName)
#endif

    For removalIndex As Long = 0 To policy.includeRemovalCount - 1
        If policy.includeRemovals(removalIndex).cHeaderName = cHeaderName Then Exit Sub
    Next
    If policy.includeRemovalCount >= MAX_FUNCTIONS Then _
        ReportError("too many -removeinclude filenames")
    If policy.includeRemovalCount > UBound(policy.includeRemovals) Then _
        ReDim Preserve policy.includeRemovals( _
            0 To UBound(policy.includeRemovals) * 2 + 1)
    policy.includeRemovals(policy.includeRemovalCount).cHeaderName = cHeaderName
    policy.includeRemovals(policy.includeRemovalCount).matched = 0
    policy.includeRemovalCount += 1
End Sub

Private Function GenericIncludeRemovedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal cHeaderName As String _
) As Long
    For position As Long = 1 To Len(cHeaderName)
        If Asc(cHeaderName, position) = Asc(Chr(92)) Then _
            Mid(cHeaderName, position, 1) = "/"
    Next
#if defined(__FB_WIN32__)
    cHeaderName = LCase(cHeaderName)
#endif
    For removalIndex As Long = 0 To policy.includeRemovalCount - 1
        If policy.includeRemovals(removalIndex).cHeaderName = cHeaderName Then
            policy.includeRemovals(removalIndex).matched = -1
            Return -1
        End If
    Next
    Return 0
End Function

Private Sub WriteGenericIncludeRemovalReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.includeRemovalCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb removed C include requests:")
    For removalIndex As Long = 0 To policy.includeRemovalCount - 1
        Dim stateText As String = "unused"
        If policy.includeRemovals(removalIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb remove include " & stateText & ": " & _
            policy.includeRemovals(removalIndex).cHeaderName)
    Next
End Sub

Private Sub AddGenericPreservedIncludeMapInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal mapText As String _
)
    Dim equalsPosition As Long = InStr(mapText, "=")
    If equalsPosition <= 1 OrElse equalsPosition >= Len(mapText) Then _
        ReportError("--preserve-include requires CHeader=FreeBasicInclude")

    Dim cHeaderPattern As String = Trim(Left(mapText, equalsPosition - 1))
    Dim freeBasicInclude As String = Trim(Mid(mapText, equalsPosition + 1))
    If (Left(cHeaderPattern, 1) = Chr(34) AndAlso _
        Right(cHeaderPattern, 1) = Chr(34)) OrElse _
       (Left(cHeaderPattern, 1) = "<" AndAlso _
        Right(cHeaderPattern, 1) = ">") Then _
        cHeaderPattern = Mid(cHeaderPattern, 2, Len(cHeaderPattern) - 2)
    If cHeaderPattern = "" OrElse freeBasicInclude = "" Then _
        ReportError("--preserve-include requires CHeader=FreeBasicInclude")
    If Len(cHeaderPattern) > 4096 OrElse Len(freeBasicInclude) > 4096 Then _
        ReportError("--preserve-include paths exceed the 4096-character limit")
    For position As Long = 1 To Len(cHeaderPattern)
        Dim currentByte As Long = Asc(cHeaderPattern, position)
        If currentByte < 32 OrElse currentByte = 127 OrElse _
           currentByte = Asc(Chr(34)) OrElse currentByte = Asc("<") OrElse _
           currentByte = Asc(">") Then _
            ReportError("--preserve-include C header patterns contain invalid characters")
        If currentByte = Asc(Chr(92)) Then Mid(cHeaderPattern, position, 1) = "/"
    Next
    For position As Long = 1 To Len(freeBasicInclude)
        Dim currentByte As Long = Asc(freeBasicInclude, position)
        If currentByte < 32 OrElse currentByte = Asc(Chr(34)) Then _
            ReportError("--preserve-include FreeBASIC paths cannot contain quotes or control characters")
    Next

    For mapIndex As Long = 0 To policy.preservedIncludeCount - 1
        If policy.preservedIncludes(mapIndex).cHeaderPattern = cHeaderPattern Then
            If policy.preservedIncludes(mapIndex).freeBasicInclude <> freeBasicInclude Then _
                ReportError("a C include pattern cannot map to multiple FreeBASIC includes")
            Exit Sub
        End If
    Next
    If policy.preservedIncludeCount >= MAX_FUNCTIONS Then _
        ReportError("too many --preserve-include mappings")
    If policy.preservedIncludeCount > UBound(policy.preservedIncludes) Then _
        ReDim Preserve policy.preservedIncludes( _
            0 To UBound(policy.preservedIncludes) * 2 + 1)
    With policy.preservedIncludes(policy.preservedIncludeCount)
        .cHeaderPattern = cHeaderPattern
        .freeBasicInclude = freeBasicInclude
        .matched = 0
    End With
    policy.preservedIncludeCount += 1
End Sub

Private Sub ResetGenericFreeBasicLibrariesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.freeBasicLibraries(0 To 15)
    policy.freeBasicLibraryCount = 0
End Sub

Private Sub AddGenericFreeBasicLibraryInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal libraryName As String _
)
    libraryName = Trim(libraryName)
    If libraryName = "" Then ReportError("FreeBASIC library name must not be empty")
    For position As Long = 1 To Len(libraryName)
        Dim currentByte As Long = Asc(libraryName, position)
        If currentByte < 32 OrElse _
           currentByte = Asc(Chr(34)) Then _
            ReportError("FreeBASIC library names cannot contain quotes or control characters")
    Next

    ' Match fbfrog's library-name translation for Microsoft and GNU filenames.
    Dim lowerName As String = LCase(libraryName)
    If Right(lowerName, 4) = ".lib" Then
        libraryName = Left(libraryName, Len(libraryName) - 4)
    ElseIf Left(lowerName, 3) = "lib" AndAlso Right(lowerName, 2) = ".a" Then
        libraryName = Mid(libraryName, 4, Len(libraryName) - 5)
    End If
    If libraryName = "" Then ReportError("FreeBASIC library name must not be empty")

    For libraryIndex As Long = 0 To policy.freeBasicLibraryCount - 1
        If policy.freeBasicLibraries(libraryIndex) = libraryName Then Exit Sub
    Next
    If policy.freeBasicLibraryCount >= MAX_FUNCTIONS Then _
        ReportError("too many FreeBASIC libraries")
    If policy.freeBasicLibraryCount > UBound(policy.freeBasicLibraries) Then _
        ReDim Preserve policy.freeBasicLibraries( _
            0 To UBound(policy.freeBasicLibraries) * 2 + 1)
    policy.freeBasicLibraries(policy.freeBasicLibraryCount) = libraryName
    policy.freeBasicLibraryCount += 1
End Sub

Private Sub ResetGenericFreeBasicUndefinesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.freeBasicUndefines(0 To 15)
    policy.freeBasicUndefineCount = 0
End Sub

Private Sub AddGenericFreeBasicUndefineInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal macroName As String _
)
    macroName = Trim(macroName)
    If macroName = "" Then _
        ReportError("--undef requires one FreeBASIC macro token")
    Dim isIdentifier As Long = _
        CInt(IsIdentifierStart(Asc(macroName, 1)) <> 0) * -1
    If isIdentifier <> 0 Then
        For position As Long = 2 To Len(macroName)
            If IsIdentifierPart(Asc(macroName, position)) = 0 Then _
                ReportError("--undef requires one FreeBASIC macro token")
        Next
    Else
        ' fbfrog permits numeric tokens in -undef options; FreeBASIC accepts
        ' them as harmless unmatched preprocessor names as well.
        For position As Long = 1 To Len(macroName)
            If Asc(macroName, position) < Asc("0") OrElse _
               Asc(macroName, position) > Asc("9") Then _
                ReportError("--undef requires one FreeBASIC macro token")
        Next
    End If
    For undefIndex As Long = 0 To policy.freeBasicUndefineCount - 1
        If policy.freeBasicUndefines(undefIndex) = macroName Then Exit Sub
    Next
    If policy.freeBasicUndefineCount >= MAX_FUNCTIONS Then _
        ReportError("too many --undef macro names")
    If policy.freeBasicUndefineCount > UBound(policy.freeBasicUndefines) Then _
        ReDim Preserve policy.freeBasicUndefines( _
            0 To UBound(policy.freeBasicUndefines) * 2 + 1)
    policy.freeBasicUndefines(policy.freeBasicUndefineCount) = macroName
    policy.freeBasicUndefineCount += 1
End Sub

Private Sub ResetGenericSymbolExcludesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.symbolExcludes(0 To 31)
    policy.symbolExcludeCount = 0
End Sub

Private Sub AddGenericSymbolExcludeInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String, _
    ByVal excludeKind As C2fbGenericSymbolExcludeKind _
)
    sourceName = Trim(sourceName)
    Dim optionName As String = "--exclude"
    Select Case excludeKind
    Case C2FB_GENERIC_SYMBOL_EXCLUDE_PROCEDURE
        optionName = "--exclude-proc"
    Case C2FB_GENERIC_SYMBOL_EXCLUDE_VARIABLE
        optionName = "--exclude-variable"
    Case C2FB_GENERIC_SYMBOL_EXCLUDE_DEFINE
        optionName = "--exclude-define"
    End Select
    If sourceName = "" OrElse _
       (IsIdentifierStart(Asc(sourceName, 1)) = 0 AndAlso _
        Asc(sourceName, 1) <> Asc("*") AndAlso Asc(sourceName, 1) <> Asc("?")) Then _
        ReportError(optionName & " requires a C identifier or wildcard pattern")
    For position As Long = 2 To Len(sourceName)
        Dim currentByte As Long = Asc(sourceName, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError(optionName & " accepts one C identifier pattern using * or ?")
    Next
    For excludeIndex As Long = 0 To policy.symbolExcludeCount - 1
        If policy.symbolExcludes(excludeIndex).sourceName = sourceName AndAlso _
           policy.symbolExcludes(excludeIndex).excludeKind = excludeKind Then Exit Sub
    Next
    If policy.symbolExcludeCount >= MAX_FUNCTIONS Then _
        ReportError("too many " & optionName & " patterns")
    If policy.symbolExcludeCount > UBound(policy.symbolExcludes) Then _
        ReDim Preserve policy.symbolExcludes(0 To UBound(policy.symbolExcludes) * 2 + 1)
    policy.symbolExcludes(policy.symbolExcludeCount).sourceName = sourceName
    policy.symbolExcludes(policy.symbolExcludeCount).excludeKind = excludeKind
    policy.symbolExcludeCount += 1
End Sub

Private Function GenericSymbolExcludedByKindInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String, _
    ByVal requestedKind As C2fbGenericSymbolExcludeKind _
) As Long
    For excludeIndex As Long = 0 To policy.symbolExcludeCount - 1
        With policy.symbolExcludes(excludeIndex)
            If requestedKind = C2FB_GENERIC_SYMBOL_EXCLUDE_ANY OrElse _
               .excludeKind = C2FB_GENERIC_SYMBOL_EXCLUDE_ANY OrElse _
               .excludeKind = requestedKind Then
                If GenericIdentifierMatchesPattern( _
                    sourceName, .sourceName) <> 0 Then Return -1
            End If
        End With
    Next
    Return 0
End Function

Private Function GenericSymbolExcludedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    Return GenericSymbolExcludedByKindInPolicy( _
        policy, sourceName, C2FB_GENERIC_SYMBOL_EXCLUDE_ANY)
End Function

Private Function GenericProcedureExcludedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    Return GenericSymbolExcludedByKindInPolicy( _
        policy, sourceName, C2FB_GENERIC_SYMBOL_EXCLUDE_PROCEDURE)
End Function

Private Function GenericVariableExcludedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    Return GenericSymbolExcludedByKindInPolicy( _
        policy, sourceName, C2FB_GENERIC_SYMBOL_EXCLUDE_VARIABLE)
End Function

Private Function GenericDefineExcludedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    Return GenericSymbolExcludedByKindInPolicy( _
        policy, sourceName, C2FB_GENERIC_SYMBOL_EXCLUDE_DEFINE)
End Function

Private Sub ResetGenericReservedMacroExportsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.reservedMacroExports(0 To 15)
    policy.reservedMacroExportCount = 0
End Sub

Private Sub AddGenericReservedMacroExportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal pattern As String _
)
    pattern = Trim(pattern)
    If pattern = "" OrElse _
       (IsIdentifierStart(Asc(pattern, 1)) = 0 AndAlso _
        Asc(pattern, 1) <> Asc("*") AndAlso Asc(pattern, 1) <> Asc("?")) Then _
        ReportError("--emit-reserved-defines requires a macro name or wildcard pattern")
    For position As Long = 2 To Len(pattern)
        Dim currentByte As Long = Asc(pattern, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("--emit-reserved-defines accepts one C macro pattern using * and ?")
    Next
    For patternIndex As Long = 0 To policy.reservedMacroExportCount - 1
        If policy.reservedMacroExports(patternIndex).pattern = pattern Then Exit Sub
    Next
    If policy.reservedMacroExportCount >= MAX_FUNCTIONS Then _
        ReportError("too many --emit-reserved-defines patterns")
    If policy.reservedMacroExportCount > UBound(policy.reservedMacroExports) Then _
        ReDim Preserve policy.reservedMacroExports( _
            0 To UBound(policy.reservedMacroExports) * 2 + 1)
    With policy.reservedMacroExports(policy.reservedMacroExportCount)
        .pattern = pattern
        .matched = 0
    End With
    policy.reservedMacroExportCount += 1
End Sub

Private Function GenericReservedMacroExportRequestedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    For patternIndex As Long = 0 To policy.reservedMacroExportCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.reservedMacroExports(patternIndex).pattern) <> 0 Then
            policy.reservedMacroExports(patternIndex).matched = -1
            Return -1
        End If
    Next
    Return 0
End Function

Private Sub WriteGenericReservedMacroExportReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.reservedMacroExportCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb reserved macro export requests:")
    For patternIndex As Long = 0 To policy.reservedMacroExportCount - 1
        Dim stateText As String = "unused"
        If policy.reservedMacroExports(patternIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb emit reserved macro " & _
            stateText & ": " & policy.reservedMacroExports(patternIndex).pattern)
    Next
End Sub

Private Sub ResetGenericOccurrenceRemovalPatternsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.removeFirstPatterns(0 To 15)
    policy.removeFirstPatternCount = 0
    ReDim policy.removeRepeatedPatterns(0 To 15)
    policy.removeRepeatedPatternCount = 0
End Sub

Private Sub AddGenericOccurrenceRemovalPatternInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal pattern As String, ByVal removeFirst As Long _
)
    pattern = Trim(pattern)
    If pattern = "" OrElse _
       (IsIdentifierStart(Asc(pattern, 1)) = 0 AndAlso _
        Asc(pattern, 1) <> Asc("*") AndAlso Asc(pattern, 1) <> Asc("?")) Then _
        ReportError("occurrence removal requires a C identifier or wildcard pattern")
    For position As Long = 2 To Len(pattern)
        Dim currentByte As Long = Asc(pattern, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("occurrence removal accepts one C identifier pattern using * or ?")
    Next

    If removeFirst <> 0 Then
        For patternIndex As Long = 0 To policy.removeFirstPatternCount - 1
            If policy.removeFirstPatterns(patternIndex).sourceName = pattern Then Exit Sub
        Next
    Else
        For patternIndex As Long = 0 To policy.removeRepeatedPatternCount - 1
            If policy.removeRepeatedPatterns(patternIndex).sourceName = pattern Then Exit Sub
        Next
    End If

    If removeFirst <> 0 Then
        If policy.removeFirstPatternCount >= MAX_FUNCTIONS Then _
            ReportError("too many -remove1st patterns")
        If policy.removeFirstPatternCount > UBound(policy.removeFirstPatterns) Then _
            ReDim Preserve policy.removeFirstPatterns( _
                0 To UBound(policy.removeFirstPatterns) * 2 + 1)
        policy.removeFirstPatterns(policy.removeFirstPatternCount).sourceName = pattern
        policy.removeFirstPatternCount += 1
    Else
        If policy.removeRepeatedPatternCount >= MAX_FUNCTIONS Then _
            ReportError("too many -remove2nd patterns")
        If policy.removeRepeatedPatternCount > UBound(policy.removeRepeatedPatterns) Then _
            ReDim Preserve policy.removeRepeatedPatterns( _
                0 To UBound(policy.removeRepeatedPatterns) * 2 + 1)
        policy.removeRepeatedPatterns(policy.removeRepeatedPatternCount).sourceName = pattern
        policy.removeRepeatedPatternCount += 1
    End If
End Sub

Private Function GenericSymbolRemoveFirstInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    For patternIndex As Long = 0 To policy.removeFirstPatternCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.removeFirstPatterns(patternIndex).sourceName) <> 0 Then _
            Return -1
    Next
    Return 0
End Function

Private Function GenericSymbolRemoveRepeatedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    For patternIndex As Long = 0 To policy.removeRepeatedPatternCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.removeRepeatedPatterns(patternIndex).sourceName) <> 0 Then _
            Return -1
    Next
    Return 0
End Function

Private Sub ResetGenericTypeExcludesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.typeExcludes(0 To 31)
    policy.typeExcludeCount = 0
End Sub

Private Sub AddGenericTypeExcludeInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
)
    sourceName = Trim(sourceName)
    If sourceName = "" OrElse _
       (IsIdentifierStart(Asc(sourceName, 1)) = 0 AndAlso _
        Asc(sourceName, 1) <> Asc("*") AndAlso Asc(sourceName, 1) <> Asc("?")) Then _
        ReportError("--exclude-type requires a C type name or wildcard pattern")
    For position As Long = 2 To Len(sourceName)
        Dim currentByte As Long = Asc(sourceName, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("--exclude-type accepts one C type name pattern using * or ?")
    Next
    For excludeIndex As Long = 0 To policy.typeExcludeCount - 1
        If policy.typeExcludes(excludeIndex).sourceName = sourceName Then Exit Sub
    Next
    If policy.typeExcludeCount >= MAX_FUNCTIONS Then _
        ReportError("too many --exclude-type names")
    If policy.typeExcludeCount > UBound(policy.typeExcludes) Then _
        ReDim Preserve policy.typeExcludes(0 To UBound(policy.typeExcludes) * 2 + 1)
    policy.typeExcludes(policy.typeExcludeCount).sourceName = sourceName
    policy.typeExcludeCount += 1
End Sub

Private Function GenericTypeExcludedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    If sourceName = "" Then Return 0
    For excludeIndex As Long = 0 To policy.typeExcludeCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.typeExcludes(excludeIndex).sourceName) <> 0 Then Return -1
    Next
    Return 0
End Function

Private Sub ResetGenericInlineMacroForcesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.inlineMacroForces(0 To 31)
    policy.inlineMacroForceCount = 0
End Sub

Private Sub AddGenericInlineMacroForceInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
)
    sourceName = Trim(sourceName)
    If sourceName = "" OrElse _
       (IsIdentifierStart(Asc(sourceName, 1)) = 0 AndAlso _
        Asc(sourceName, 1) <> Asc("*") AndAlso Asc(sourceName, 1) <> Asc("?")) Then _
        ReportError("--force-inline-macro requires a C function name or wildcard pattern")
    For position As Long = 2 To Len(sourceName)
        Dim currentByte As Long = Asc(sourceName, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("--force-inline-macro accepts one C function name pattern using * or ?")
    Next
    For forceIndex As Long = 0 To policy.inlineMacroForceCount - 1
        If policy.inlineMacroForces(forceIndex).sourceName = sourceName Then
            policy.inlineMacroForces(forceIndex).matched = 0
            Exit Sub
        End If
    Next
    If policy.inlineMacroForceCount >= MAX_FUNCTIONS Then _
        ReportError("too many --force-inline-macro patterns")
    If policy.inlineMacroForceCount > UBound(policy.inlineMacroForces) Then _
        ReDim Preserve policy.inlineMacroForces( _
            0 To UBound(policy.inlineMacroForces) * 2 + 1)
    policy.inlineMacroForces(policy.inlineMacroForceCount).sourceName = sourceName
    policy.inlineMacroForces(policy.inlineMacroForceCount).matched = 0
    policy.inlineMacroForceCount += 1
End Sub

Private Function GenericInlineMacroForcedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourceName As String, ByVal markMatched As Long = 0 _
) As Long
    For forceIndex As Long = 0 To policy.inlineMacroForceCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.inlineMacroForces(forceIndex).sourceName) <> 0 Then
            If markMatched <> 0 Then _
                policy.inlineMacroForces(forceIndex).matched = -1
            Return -1
        End If
    Next
    Return 0
End Function

Private Sub ResetGenericInlineBodyDropsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.inlineBodyDrops(0 To 31)
    policy.inlineBodyDropCount = 0
End Sub

Private Sub AddGenericInlineBodyDropInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
)
    sourceName = Trim(sourceName)
    If sourceName = "" OrElse _
       (IsIdentifierStart(Asc(sourceName, 1)) = 0 AndAlso _
        Asc(sourceName, 1) <> Asc("*") AndAlso Asc(sourceName, 1) <> Asc("?")) Then _
        ReportError("--drop-inline-body requires a C function name or wildcard pattern")
    For position As Long = 2 To Len(sourceName)
        Dim currentByte As Long = Asc(sourceName, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("--drop-inline-body accepts one C function name pattern using * or ?")
    Next
    For dropIndex As Long = 0 To policy.inlineBodyDropCount - 1
        If policy.inlineBodyDrops(dropIndex).sourceName = sourceName Then
            policy.inlineBodyDrops(dropIndex).matched = 0
            Exit Sub
        End If
    Next
    If policy.inlineBodyDropCount >= MAX_FUNCTIONS Then _
        ReportError("too many --drop-inline-body patterns")
    If policy.inlineBodyDropCount > UBound(policy.inlineBodyDrops) Then _
        ReDim Preserve policy.inlineBodyDrops( _
            0 To UBound(policy.inlineBodyDrops) * 2 + 1)
    policy.inlineBodyDrops(policy.inlineBodyDropCount).sourceName = sourceName
    policy.inlineBodyDrops(policy.inlineBodyDropCount).matched = 0
    policy.inlineBodyDropCount += 1
End Sub

Private Function GenericInlineBodyDroppedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String _
) As Long
    Dim matched As Long = 0
    For dropIndex As Long = 0 To policy.inlineBodyDropCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.inlineBodyDrops(dropIndex).sourceName) <> 0 Then
            policy.inlineBodyDrops(dropIndex).matched = -1
            matched = -1
        End If
    Next
    Return matched
End Function

Private Sub SetGenericNamePrefixInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal namePrefix As String _
)
    namePrefix = Trim(namePrefix)
    If namePrefix = "" OrElse IsIdentifierStart(Asc(namePrefix, 1)) = 0 Then _
        ReportError("--prefix must begin with a FreeBASIC identifier character")
    For position As Long = 2 To Len(namePrefix)
        If IsIdentifierPart(Asc(namePrefix, position)) = 0 Then _
            ReportError("--prefix must contain only identifier characters")
    Next
    policy.generatedNamePrefix = namePrefix
End Sub

Private Sub SetGenericProcedureNamePrefixInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal namePrefix As String _
)
    namePrefix = Trim(namePrefix)
    If namePrefix = "" OrElse IsIdentifierStart(Asc(namePrefix, 1)) = 0 Then _
        ReportError("--rename-proc-prefix must begin with a FreeBASIC identifier character")
    For position As Long = 2 To Len(namePrefix)
        If IsIdentifierPart(Asc(namePrefix, position)) = 0 Then _
            ReportError("--rename-proc-prefix must contain only identifier characters")
    Next
    policy.procedureNamePrefix = namePrefix
    policy.procedureNamePrefixMatched = 0
End Sub

Private Function GenericIdentifierMatchesPattern( _
    ByVal sourceName As String, ByVal pattern As String _
) As Long
    ' Keep only the most recent '*' and extend it on mismatch, avoiding
    ' recursion or a table proportional to both input lengths.
    Dim sourcePosition As Long = 1
    Dim patternPosition As Long = 1
    Dim lastWildcard As Long = 0
    Dim wildcardSourcePosition As Long = 0

    While sourcePosition <= Len(sourceName)
        If patternPosition <= Len(pattern) AndAlso _
           (Mid(pattern, patternPosition, 1) = "?" OrElse _
            Mid(pattern, patternPosition, 1) = Mid(sourceName, sourcePosition, 1)) Then
            sourcePosition += 1
            patternPosition += 1
        ElseIf patternPosition <= Len(pattern) AndAlso _
               Mid(pattern, patternPosition, 1) = "*" Then
            lastWildcard = patternPosition
            patternPosition += 1
            wildcardSourcePosition = sourcePosition
        ElseIf lastWildcard > 0 Then
            wildcardSourcePosition += 1
            sourcePosition = wildcardSourcePosition
            patternPosition = lastWildcard + 1
        Else
            Return 0
        End If
    Wend

    While patternPosition <= Len(pattern) AndAlso _
          Mid(pattern, patternPosition, 1) = "*"
        patternPosition += 1
    Wend
    Return CInt(patternPosition > Len(pattern))
End Function

Private Sub ResetGenericDeclarationGuardsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.ifndefDeclarationPatterns(0 To 15)
    policy.ifndefDeclarationPatternCount = 0
    ReDim policy.undefBeforeDeclarationPatterns(0 To 15)
    policy.undefBeforeDeclarationPatternCount = 0
End Sub

Private Sub AddGenericDeclarationGuardPatternInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal namePattern As String, ByVal isUndefBefore As Long _
)
    namePattern = Trim(namePattern)
    If namePattern = "" OrElse Len(namePattern) > 4096 Then _
        ReportError("declaration guard pattern must contain 1 to 4096 characters")
    If IsIdentifierStart(Asc(namePattern, 1)) = 0 AndAlso _
       Asc(namePattern, 1) <> Asc("*") AndAlso _
       Asc(namePattern, 1) <> Asc("?") Then _
        ReportError("declaration guard patterns must be identifiers or use * and ?")
    For position As Long = 2 To Len(namePattern)
        Dim currentByte As Long = Asc(namePattern, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("declaration guard patterns must be identifiers or use * and ?")
    Next

    If isUndefBefore <> 0 Then
        For patternIndex As Long = 0 To _
            policy.undefBeforeDeclarationPatternCount - 1
            If policy.undefBeforeDeclarationPatterns(patternIndex).pattern = _
               namePattern Then Exit Sub
        Next
    Else
        For patternIndex As Long = 0 To _
            policy.ifndefDeclarationPatternCount - 1
            If policy.ifndefDeclarationPatterns(patternIndex).pattern = _
               namePattern Then Exit Sub
        Next
    End If

    If isUndefBefore <> 0 Then
        If policy.undefBeforeDeclarationPatternCount >= MAX_FUNCTIONS Then _
            ReportError("too many --undef-before-decl patterns")
        If policy.undefBeforeDeclarationPatternCount > _
           UBound(policy.undefBeforeDeclarationPatterns) Then _
            ReDim Preserve policy.undefBeforeDeclarationPatterns( _
                0 To UBound(policy.undefBeforeDeclarationPatterns) * 2 + 1)
        With policy.undefBeforeDeclarationPatterns( _
            policy.undefBeforeDeclarationPatternCount)
            .pattern = namePattern
            .matched = 0
        End With
        policy.undefBeforeDeclarationPatternCount += 1
    Else
        If policy.ifndefDeclarationPatternCount >= MAX_FUNCTIONS Then _
            ReportError("too many --ifndef-decl patterns")
        If policy.ifndefDeclarationPatternCount > _
           UBound(policy.ifndefDeclarationPatterns) Then _
            ReDim Preserve policy.ifndefDeclarationPatterns( _
                0 To UBound(policy.ifndefDeclarationPatterns) * 2 + 1)
        With policy.ifndefDeclarationPatterns( _
            policy.ifndefDeclarationPatternCount)
            .pattern = namePattern
            .matched = 0
        End With
        policy.ifndefDeclarationPatternCount += 1
    End If
End Sub

Private Function GenericDeclarationGuardNameInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal isUndefBefore As Long, _
    ByVal sourceName As String, ByVal freeBasicName As String _
) As String
    Dim patternCount As Long = policy.ifndefDeclarationPatternCount
    Dim guardName As String
    If isUndefBefore <> 0 Then _
        patternCount = policy.undefBeforeDeclarationPatternCount
    For patternIndex As Long = 0 To patternCount - 1
        Dim matched As Long = 0
        Dim namePattern As String
        If isUndefBefore <> 0 Then
            namePattern = policy.undefBeforeDeclarationPatterns(patternIndex).pattern
        Else
            namePattern = policy.ifndefDeclarationPatterns(patternIndex).pattern
        End If
        If sourceName <> "" AndAlso GenericIdentifierMatchesPattern( _
            sourceName, namePattern) <> 0 Then matched = -1
        If freeBasicName <> "" AndAlso GenericIdentifierMatchesPattern( _
            LCase(freeBasicName), LCase(namePattern)) <> 0 Then _
            matched = -1
        If matched <> 0 Then
            If isUndefBefore <> 0 Then
                policy.undefBeforeDeclarationPatterns(patternIndex).matched = -1
            Else
                policy.ifndefDeclarationPatterns(patternIndex).matched = -1
            End If
            If guardName = "" Then guardName = freeBasicName
        End If
    Next
    Return guardName
End Function

Private Function GenericDeclarationIfndefGuardNameInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourceName As String, ByVal freeBasicName As String _
) As String
    Return GenericDeclarationGuardNameInPolicy( _
        policy, 0, sourceName, freeBasicName)
End Function

Private Function GenericDeclarationUndefBeforeNameInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourceName As String, ByVal freeBasicName As String _
) As String
    Return GenericDeclarationGuardNameInPolicy( _
        policy, -1, sourceName, freeBasicName)
End Function

Private Sub WriteGenericProcedureBindingWithGuardsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByVal sourceName As String, _
    ByRef binding As C2fbProcedureBindingModel _
)
    WriteC2fbProcedureBinding( _
        outputFile, binding, _
        GenericDeclarationIfndefGuardNameInPolicy( _
            policy, sourceName, binding.freeBasicName), _
        GenericDeclarationUndefBeforeNameInPolicy( _
            policy, sourceName, binding.freeBasicName))
End Sub

Private Sub WriteGenericObjectBindingWithGuardsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByVal sourceName As String, _
    ByRef binding As C2fbObjectBindingModel _
)
    If binding.isModuleStatic <> 0 Then _
        WriteC2fbOutputLine( _
            outputFile, "' c2fb static-object: " & binding.cName & _
                "=" & binding.freeBasicName)
    WriteC2fbObjectBinding( _
        outputFile, binding, _
        GenericDeclarationIfndefGuardNameInPolicy( _
            policy, sourceName, binding.freeBasicName), _
        GenericDeclarationUndefBeforeNameInPolicy( _
            policy, sourceName, binding.freeBasicName))
End Sub

Private Sub WriteGenericTypeAliasWithGuardsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByVal sourceName As String, _
    ByRef binding As C2fbTypeAliasBindingModel _
)
    WriteC2fbTypeAlias( _
        outputFile, binding, _
        GenericDeclarationIfndefGuardNameInPolicy( _
            policy, sourceName, binding.freeBasicName), _
        GenericDeclarationUndefBeforeNameInPolicy( _
            policy, sourceName, binding.freeBasicName))
End Sub

Private Sub WriteGenericTypeAliasByNameWithGuardsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByVal sourceName As String, ByVal freeBasicName As String, _
    ByVal targetType As String _
)
    Dim binding As C2fbTypeAliasBindingModel
    binding.freeBasicName = freeBasicName
    binding.targetType = targetType
    WriteGenericTypeAliasWithGuardsInPolicy( _
        policy, outputFile, sourceName, binding)
End Sub

Private Sub WriteGenericConstantBindingWithGuardsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByVal sourceName As String, _
    ByRef binding As C2fbConstantBindingModel _
)
    WriteC2fbConstantBinding( _
        outputFile, binding, _
        GenericDeclarationIfndefGuardNameInPolicy( _
            policy, sourceName, binding.freeBasicName), _
        GenericDeclarationUndefBeforeNameInPolicy( _
            policy, sourceName, binding.freeBasicName))
End Sub

Private Sub WriteGenericMacroBindingWithGuardsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByVal sourceName As String, _
    ByRef binding As C2fbMacroBindingModel _
)
    WriteC2fbMacroBinding( _
        outputFile, binding, _
        GenericDeclarationIfndefGuardNameInPolicy( _
            policy, sourceName, binding.name), _
        GenericDeclarationUndefBeforeNameInPolicy( _
            policy, sourceName, binding.name))
End Sub

Private Sub WriteGenericDeclarationGuardReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.ifndefDeclarationPatternCount = 0 AndAlso _
       policy.undefBeforeDeclarationPatternCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb declaration guard patterns:")
    For patternIndex As Long = 0 To policy.ifndefDeclarationPatternCount - 1
        Dim stateText As String = "unused"
        If policy.ifndefDeclarationPatterns(patternIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb ifndef-decl " & stateText & ": " & _
            policy.ifndefDeclarationPatterns(patternIndex).pattern)
    Next
    For patternIndex As Long = 0 To policy.undefBeforeDeclarationPatternCount - 1
        Dim stateText As String = "unused"
        If policy.undefBeforeDeclarationPatterns(patternIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb undef-before-decl " & stateText & ": " & _
            policy.undefBeforeDeclarationPatterns(patternIndex).pattern)
    Next
End Sub

Private Sub ResetGenericMacroTokenConversionsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.macroTokenConversions(0 To 15)
    policy.macroTokenConversionCount = 0
End Sub

Private Sub AddGenericMacroTokenConversionInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal namePattern As String _
)
    namePattern = Trim(namePattern)
    If namePattern = "" OrElse Len(namePattern) > 4096 Then _
        ReportError("macro token pattern must contain 1 to 4096 characters")
    If IsIdentifierStart(Asc(namePattern, 1)) = 0 AndAlso _
       Asc(namePattern, 1) <> Asc("*") AndAlso _
       Asc(namePattern, 1) <> Asc("?") Then _
        ReportError("macro token patterns must be identifiers or use * and ?")
    For position As Long = 2 To Len(namePattern)
        Dim currentByte As Long = Asc(namePattern, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("macro token patterns must be identifiers or use * and ?")
    Next
    For patternIndex As Long = 0 To policy.macroTokenConversionCount - 1
        If policy.macroTokenConversions(patternIndex).pattern = namePattern Then Exit Sub
    Next
    If policy.macroTokenConversionCount >= MAX_FUNCTIONS Then _
        ReportError("too many --convert-macro-tokens patterns")
    If policy.macroTokenConversionCount > UBound(policy.macroTokenConversions) Then _
        ReDim Preserve policy.macroTokenConversions( _
            0 To UBound(policy.macroTokenConversions) * 2 + 1)
    policy.macroTokenConversions(policy.macroTokenConversionCount).pattern = namePattern
    policy.macroTokenConversions(policy.macroTokenConversionCount).matched = 0
    policy.macroTokenConversionCount += 1
End Sub

Private Function GenericMacroTokenConversionForcedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String, _
    ByVal markMatched As Long = -1 _
) As Long
    For patternIndex As Long = 0 To policy.macroTokenConversionCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.macroTokenConversions(patternIndex).pattern) <> 0 Then
            If markMatched <> 0 Then _
                policy.macroTokenConversions(patternIndex).matched = -1
            Return -1
        End If
    Next
    Return 0
End Function

Private Sub WriteGenericMacroTokenConversionReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.macroTokenConversionCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb macro token conversion patterns:")
    For patternIndex As Long = 0 To policy.macroTokenConversionCount - 1
        Dim stateText As String = "unused"
        If policy.macroTokenConversions(patternIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb convert macro tokens " & _
            stateText & ": " & policy.macroTokenConversions(patternIndex).pattern)
    Next
End Sub

Private Sub ResetGenericIntegerMacroAssumptionsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.integerMacroAssumptions(0 To 15)
    policy.integerMacroAssumptionCount = 0
End Sub

Private Sub AddGenericIntegerMacroAssumptionInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal namePattern As String _
)
    namePattern = Trim(namePattern)
    If namePattern = "" OrElse Len(namePattern) > 4096 Then _
        ReportError("integer macro pattern must contain 1 to 4096 characters")
    If IsIdentifierStart(Asc(namePattern, 1)) = 0 AndAlso _
       Asc(namePattern, 1) <> Asc("*") AndAlso _
       Asc(namePattern, 1) <> Asc("?") Then _
        ReportError("integer macro patterns must be identifiers or use * and ?")
    For position As Long = 2 To Len(namePattern)
        Dim currentByte As Long = Asc(namePattern, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("integer macro patterns must be identifiers or use * and ?")
    Next
    For patternIndex As Long = 0 To policy.integerMacroAssumptionCount - 1
        If policy.integerMacroAssumptions(patternIndex).pattern = namePattern Then Exit Sub
    Next
    If policy.integerMacroAssumptionCount >= MAX_FUNCTIONS Then _
        ReportError("too many --assume-integer-macro patterns")
    If policy.integerMacroAssumptionCount > _
       UBound(policy.integerMacroAssumptions) Then _
        ReDim Preserve policy.integerMacroAssumptions( _
            0 To UBound(policy.integerMacroAssumptions) * 2 + 1)
    policy.integerMacroAssumptions( _
        policy.integerMacroAssumptionCount).pattern = namePattern
    policy.integerMacroAssumptions( _
        policy.integerMacroAssumptionCount).matched = 0
    policy.integerMacroAssumptionCount += 1
End Sub

Private Function GenericIntegerMacroAssumedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String, _
    ByVal markMatched As Long = 0 _
) As Long
    Dim matched As Long = 0
    For patternIndex As Long = 0 To policy.integerMacroAssumptionCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.integerMacroAssumptions(patternIndex).pattern) <> 0 Then
            If markMatched <> 0 Then _
                policy.integerMacroAssumptions(patternIndex).matched = -1
            matched = -1
        End If
    Next
    Return matched
End Function

Private Sub WriteGenericIntegerMacroAssumptionReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.integerMacroAssumptionCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb assume-integer-macro patterns:")
    For patternIndex As Long = 0 To policy.integerMacroAssumptionCount - 1
        Dim stateText As String = "unused"
        If policy.integerMacroAssumptions(patternIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb assume-integer-macro " & _
            stateText & ": " & policy.integerMacroAssumptions(patternIndex).pattern)
    Next
End Sub

Private Sub ResetGenericDynamicMacroDivisionsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.dynamicMacroDivisions(0 To 15)
    policy.dynamicMacroDivisionCount = 0
End Sub

Private Sub AddGenericDynamicMacroDivisionInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal namePattern As String _
)
    namePattern = Trim(namePattern)
    If namePattern = "" OrElse Len(namePattern) > 4096 Then _
        ReportError("dynamic macro division pattern must contain 1 to 4096 characters")
    If IsIdentifierStart(Asc(namePattern, 1)) = 0 AndAlso _
       Asc(namePattern, 1) <> Asc("*") AndAlso _
       Asc(namePattern, 1) <> Asc("?") Then _
        ReportError("dynamic macro division patterns must be identifiers or use * and ?")
    For position As Long = 2 To Len(namePattern)
        Dim currentByte As Long = Asc(namePattern, position)
        If IsIdentifierPart(currentByte) = 0 AndAlso _
           currentByte <> Asc("*") AndAlso currentByte <> Asc("?") Then _
            ReportError("dynamic macro division patterns must be identifiers or use * and ?")
    Next
    For patternIndex As Long = 0 To policy.dynamicMacroDivisionCount - 1
        If policy.dynamicMacroDivisions(patternIndex).pattern = namePattern Then Exit Sub
    Next
    If policy.dynamicMacroDivisionCount >= MAX_FUNCTIONS Then _
        ReportError("too many --dynamic-macro-division patterns")
    If policy.dynamicMacroDivisionCount > _
       UBound(policy.dynamicMacroDivisions) Then _
        ReDim Preserve policy.dynamicMacroDivisions( _
            0 To UBound(policy.dynamicMacroDivisions) * 2 + 1)
    policy.dynamicMacroDivisions( _
        policy.dynamicMacroDivisionCount).pattern = namePattern
    policy.dynamicMacroDivisions( _
        policy.dynamicMacroDivisionCount).matched = 0
    policy.dynamicMacroDivisionCount += 1
End Sub

Private Function GenericMacroDivisionDynamicInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourceName As String, _
    ByVal markMatched As Long = 0 _
) As Long
    Dim matched As Long = 0
    For patternIndex As Long = 0 To policy.dynamicMacroDivisionCount - 1
        If GenericIdentifierMatchesPattern( _
            sourceName, policy.dynamicMacroDivisions(patternIndex).pattern) <> 0 Then
            If markMatched <> 0 Then _
                policy.dynamicMacroDivisions(patternIndex).matched = -1
            matched = -1
        End If
    Next
    Return matched
End Function

Private Sub WriteGenericDynamicMacroDivisionReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.dynamicMacroDivisionCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb dynamic macro division patterns:")
    For patternIndex As Long = 0 To policy.dynamicMacroDivisionCount - 1
        Dim stateText As String = "unused"
        If policy.dynamicMacroDivisions(patternIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb dynamic macro division " & _
            stateText & ": " & policy.dynamicMacroDivisions(patternIndex).pattern)
    Next
End Sub

Private Sub ResetGenericSourcePatternsInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.sourceIncludes(0 To 31)
    policy.sourceIncludeCount = 0
    ReDim policy.sourceExcludes(0 To 31)
    policy.sourceExcludeCount = 0
    ReDim policy.sourceRoutes(0 To 31)
    policy.sourceRouteCount = 0
    policy.sourceDestination = ""
End Sub

Private Sub ResetGenericMoveAboveInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.moveAboveMappings(0 To 15)
    policy.moveAboveCount = 0
End Sub

Private Sub AddGenericMoveAboveInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal movingName As String, ByVal referenceName As String _
)
    movingName = Trim(movingName)
    referenceName = Trim(referenceName)
    If movingName = "" OrElse referenceName = "" OrElse _
       IsIdentifierStart(Asc(movingName, 1)) = 0 OrElse _
       IsIdentifierStart(Asc(referenceName, 1)) = 0 Then _
        ReportError("--move-above requires two C or FreeBASIC identifiers")
    For position As Long = 2 To Len(movingName)
        If IsIdentifierPart(Asc(movingName, position)) = 0 Then _
            ReportError("--move-above names must be identifiers")
    Next
    For position As Long = 2 To Len(referenceName)
        If IsIdentifierPart(Asc(referenceName, position)) = 0 Then _
            ReportError("--move-above names must be identifiers")
    Next
    If policy.moveAboveCount >= MAX_FUNCTIONS Then _
        ReportError("too many --move-above mappings")
    If policy.moveAboveCount > UBound(policy.moveAboveMappings) Then _
        ReDim Preserve policy.moveAboveMappings( _
            0 To UBound(policy.moveAboveMappings) * 2 + 1)
    With policy.moveAboveMappings(policy.moveAboveCount)
        .movingName = movingName
        .referenceName = referenceName
        .matched = 0
        .applied = 0
        .hoisted = 0
        .failureReason = ""
    End With
    policy.moveAboveCount += 1
End Sub

Private Sub ParseGenericMoveAboveArgumentInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal moveText As String _
)
    Dim equalsPosition As Long = InStr(moveText, "=")
    If equalsPosition <= 1 OrElse equalsPosition >= Len(moveText) Then _
        ReportError("--move-above requires Name=ReferenceName")
    AddGenericMoveAboveInPolicy( _
        policy, Left(moveText, equalsPosition - 1), Mid(moveText, equalsPosition + 1))
End Sub

Private Sub WriteGenericMoveAboveReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.moveAboveCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb move-above mappings:")
    For moveIndex As Long = 0 To policy.moveAboveCount - 1
        Dim stateText As String = "unused"
        If policy.moveAboveMappings(moveIndex).applied <> 0 Then
            stateText = "applied"
        ElseIf policy.moveAboveMappings(moveIndex).failureReason <> "" Then
            stateText = "not applied (" & _
                policy.moveAboveMappings(moveIndex).failureReason & ")"
        ElseIf policy.moveAboveMappings(moveIndex).matched <> 0 Then
            stateText = "matched but not applied"
        End If
        WriteC2fbOutputLine(outputFile, "' c2fb move-above " & stateText & ": " & _
            policy.moveAboveMappings(moveIndex).movingName & " -> " & _
            policy.moveAboveMappings(moveIndex).referenceName)
    Next
End Sub

Private Sub AddGenericSourcePatternInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourcePattern As String, ByVal isExclude As Long, _
    ByVal isAutomatic As Long = 0 _
)
    sourcePattern = Trim(sourcePattern)
    If sourcePattern = "" OrElse Len(sourcePattern) > 4096 Then _
        ReportError("source pattern must contain 1 to 4096 characters")
    For position As Long = 1 To Len(sourcePattern)
        If Asc(sourcePattern, position) < 32 OrElse _
           Asc(sourcePattern, position) = 127 Then _
            ReportError("source patterns cannot contain control characters")
        If Asc(sourcePattern, position) = Asc(Chr(92)) Then _
            Mid(sourcePattern, position, 1) = "/"
    Next

    If isExclude <> 0 Then
        For patternIndex As Long = 0 To policy.sourceExcludeCount - 1
            If policy.sourceExcludes(patternIndex).pattern = sourcePattern Then Exit Sub
        Next
        If policy.sourceExcludeCount >= MAX_FUNCTIONS Then _
            ReportError("too many source exclusions")
        If policy.sourceExcludeCount > UBound(policy.sourceExcludes) Then _
            ReDim Preserve policy.sourceExcludes( _
                0 To UBound(policy.sourceExcludes) * 2 + 1)
        policy.sourceExcludes(policy.sourceExcludeCount).pattern = sourcePattern
        policy.sourceExcludes(policy.sourceExcludeCount).automatic = isAutomatic
        policy.sourceExcludeCount += 1
    Else
        For patternIndex As Long = 0 To policy.sourceIncludeCount - 1
            If policy.sourceIncludes(patternIndex).pattern = sourcePattern Then Exit Sub
        Next
        If policy.sourceIncludeCount >= MAX_FUNCTIONS Then _
            ReportError("too many source inclusions")
        If policy.sourceIncludeCount > UBound(policy.sourceIncludes) Then _
            ReDim Preserve policy.sourceIncludes( _
                0 To UBound(policy.sourceIncludes) * 2 + 1)
        policy.sourceIncludes(policy.sourceIncludeCount).pattern = sourcePattern
        policy.sourceIncludes(policy.sourceIncludeCount).automatic = isAutomatic
        policy.sourceIncludeCount += 1
    End If
End Sub

Private Sub AddGenericSourceRouteInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourcePattern As String, ByVal destination As String _
)
    sourcePattern = Trim(sourcePattern)
    destination = Trim(destination)
    If sourcePattern = "" OrElse Len(sourcePattern) > 4096 Then _
        ReportError("source route pattern must contain 1 to 4096 characters")
    If destination = "" OrElse Len(destination) > 256 Then _
        ReportError("source route destination must contain 1 to 256 characters")
    For position As Long = 1 To Len(sourcePattern)
        If Asc(sourcePattern, position) < 32 OrElse _
           Asc(sourcePattern, position) = 127 Then _
            ReportError("source route patterns cannot contain control characters")
#if defined(__FB_WIN32__) or defined(__FB_DOS__)
        If Asc(sourcePattern, position) = Asc(Chr(92)) Then _
            Mid(sourcePattern, position, 1) = "/"
#endif
    Next
    For position As Long = 1 To Len(destination)
        If Asc(destination, position) < 32 OrElse _
           Asc(destination, position) = 127 Then _
            ReportError("source route destinations cannot contain control characters")
    Next
    If policy.sourceRouteCount >= MAX_FUNCTIONS Then _
        ReportError("too many source route rules")
    If policy.sourceRouteCount > UBound(policy.sourceRoutes) Then _
        ReDim Preserve policy.sourceRoutes( _
            0 To UBound(policy.sourceRoutes) * 2 + 1)
    policy.sourceRoutes(policy.sourceRouteCount).pattern = sourcePattern
    policy.sourceRoutes(policy.sourceRouteCount).destination = destination
    policy.sourceRouteCount += 1
End Sub

Private Sub SetGenericSourceDestinationInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal destination As String _
)
    destination = Trim(destination)
    If destination = "" OrElse Len(destination) > 256 Then _
        ReportError("source destination must contain 1 to 256 characters")
    If policy.sourceDestination <> "" Then _
        ReportError("--source-destination was specified more than once")
    For position As Long = 1 To Len(destination)
        If Asc(destination, position) < 32 OrElse _
           Asc(destination, position) = 127 Then _
            ReportError("source destinations cannot contain control characters")
    Next
    policy.sourceDestination = destination
End Sub

Private Function GenericSourcePathMatchesPatternInPolicy( _
    ByVal sourcePath As String, ByVal sourcePattern As String _
) As Long
    sourcePath = Trim(sourcePath)
    sourcePattern = Trim(sourcePattern)
    If sourcePath = "" OrElse sourcePattern = "" Then Return 0
    For position As Long = 1 To Len(sourcePath)
        If Asc(sourcePath, position) = Asc(Chr(92)) Then _
            Mid(sourcePath, position, 1) = "/"
    Next
#if defined(__FB_WIN32__)
    sourcePath = LCase(sourcePath)
    sourcePattern = LCase(sourcePattern)
#endif

    ' Source markers may be absolute while users naturally specify a path
    ' relative to the project. Treat the pattern as a path suffix.
    If Left(sourcePattern, 1) <> "*" Then sourcePattern = "*" & sourcePattern
    Return GenericIdentifierMatchesPattern(sourcePath, sourcePattern)
End Function

Private Function GenericSourcePathMatchesRoutePatternInPolicy( _
    ByVal sourcePath As String, ByVal sourcePattern As String _
) As Long
    sourcePath = Trim(sourcePath)
    sourcePattern = Trim(sourcePattern)
    If sourcePath = "" OrElse sourcePattern = "" Then Return 0
#if defined(__FB_WIN32__) or defined(__FB_DOS__)
    For position As Long = 1 To Len(sourcePath)
        If Asc(sourcePath, position) = Asc(Chr(92)) Then _
            Mid(sourcePath, position, 1) = "/"
    Next
#endif
    Return GenericIdentifierMatchesPattern(sourcePath, sourcePattern)
End Function

Private Function GenericSourceRouteMatchesDestinationInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourcePath As String _
) As Long
    If policy.sourceRouteCount = 0 Then Return -1
    If policy.sourceDestination = "" Then _
        ReportError("source routes require --source-destination")
    For routeIndex As Long = 0 To policy.sourceRouteCount - 1
        If GenericSourcePathMatchesRoutePatternInPolicy( _
            sourcePath, policy.sourceRoutes(routeIndex).pattern) <> 0 Then
            Return CInt(LCase(policy.sourceRoutes(routeIndex).destination) = _
                        LCase(policy.sourceDestination))
        End If
    Next
    Return 0
End Function

Private Function GenericPreservedIncludeMapIndexInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal cHeaderName As String _
) As Long
    For mapIndex As Long = 0 To policy.preservedIncludeCount - 1
        Dim cHeaderPattern As String = _
            policy.preservedIncludes(mapIndex).cHeaderPattern
        For position As Long = 1 To Len(cHeaderName)
            If Asc(cHeaderName, position) = Asc(Chr(92)) Then _
                Mid(cHeaderName, position, 1) = "/"
        Next
#if defined(__FB_WIN32__)
        cHeaderName = LCase(cHeaderName)
        cHeaderPattern = LCase(cHeaderPattern)
#endif
        If GenericIdentifierMatchesPattern(cHeaderName, cHeaderPattern) <> 0 Then _
            Return mapIndex
    Next
    Return -1
End Function

Private Function GenericSourceIncludedInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourcePath As String _
) As Long
    If GenericSourceRouteMatchesDestinationInPolicy( _
        policy, sourcePath) = 0 Then Return 0
    Dim isIncluded As Long = -1
    If policy.sourceIncludeCount > 0 Then isIncluded = 0
    For patternIndex As Long = 0 To policy.sourceIncludeCount - 1
        If GenericSourcePathMatchesPatternInPolicy( _
            sourcePath, policy.sourceIncludes(patternIndex).pattern) <> 0 Then
            policy.sourceIncludes(patternIndex).matched = -1
            isIncluded = -1
        End If
    Next
    For patternIndex As Long = 0 To policy.sourceExcludeCount - 1
        If GenericSourcePathMatchesPatternInPolicy( _
            sourcePath, policy.sourceExcludes(patternIndex).pattern) <> 0 Then
            policy.sourceExcludes(patternIndex).matched = -1
            isIncluded = 0
        End If
    Next
    Return isIncluded
End Function

Private Function GenericSourceIncludedForPreservedIncludeInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal sourcePath As String _
) As Long
    If GenericSourceRouteMatchesDestinationInPolicy( _
        policy, sourcePath) = 0 Then Return 0
    Dim isIncluded As Long = -1
    If policy.sourceIncludeCount > 0 Then isIncluded = 0
    For patternIndex As Long = 0 To policy.sourceIncludeCount - 1
        If GenericSourcePathMatchesPatternInPolicy( _
            sourcePath, policy.sourceIncludes(patternIndex).pattern) <> 0 Then
            policy.sourceIncludes(patternIndex).matched = -1
            isIncluded = -1
        End If
    Next
    For patternIndex As Long = 0 To policy.sourceExcludeCount - 1
        If policy.sourceExcludes(patternIndex).automatic = 0 AndAlso _
           GenericSourcePathMatchesPatternInPolicy( _
            sourcePath, policy.sourceExcludes(patternIndex).pattern) <> 0 Then
            policy.sourceExcludes(patternIndex).matched = -1
            isIncluded = 0
        End If
    Next
    Return isIncluded
End Function

Private Sub WriteGenericSourcePatternReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.sourceIncludeCount = 0 AndAlso _
       policy.sourceExcludeCount = 0 AndAlso _
       policy.sourceRouteCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb source patterns:")
    For patternIndex As Long = 0 To policy.sourceIncludeCount - 1
        Dim stateText As String = "unused"
        If policy.sourceIncludes(patternIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb emit source " & stateText & ": " & _
            policy.sourceIncludes(patternIndex).pattern)
    Next
    For patternIndex As Long = 0 To policy.sourceExcludeCount - 1
        If policy.sourceExcludes(patternIndex).automatic <> 0 Then Continue For
        Dim stateText As String = "unused"
        If policy.sourceExcludes(patternIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb exclude source " & stateText & ": " & _
            policy.sourceExcludes(patternIndex).pattern)
    Next
    If policy.sourceRouteCount > 0 Then
        WriteC2fbOutputLine(outputFile, "' c2fb selected source destination: " & _
            policy.sourceDestination)
        For routeIndex As Long = 0 To policy.sourceRouteCount - 1
            WriteC2fbOutputLine(outputFile, "' c2fb source route: " & _
                policy.sourceRoutes(routeIndex).pattern & " -> " & _
                policy.sourceRoutes(routeIndex).destination)
        Next
    End If
End Sub

Private Sub WriteGenericPreservedIncludeReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.preservedIncludeCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb preserved C include mappings:")
    For mapIndex As Long = 0 To policy.preservedIncludeCount - 1
        Dim stateText As String = "unused"
        If policy.preservedIncludes(mapIndex).matched <> 0 Then stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb preserved include " & stateText & ": " & _
            policy.preservedIncludes(mapIndex).cHeaderPattern & " -> " & _
            policy.preservedIncludes(mapIndex).freeBasicInclude)
    Next
End Sub

Private Sub ParseGenericSymbolRenameArgumentInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal renameText As String, _
    ByVal renameNamespace As C2fbSymbolRenameNamespace = _
        C2FB_SYMBOL_RENAME_GENERAL _
)
    Dim equalsPosition As Long = InStr(renameText, "=")
    If equalsPosition <= 1 OrElse equalsPosition >= Len(renameText) Then _
        ReportError("symbol rename must have the form CName=FbName")
    AddGenericSymbolRenameInPolicy( _
        policy, Left(renameText, equalsPosition - 1), _
        Mid(renameText, equalsPosition + 1), renameNamespace)
End Sub

Private Sub ParseGenericStaticObjectLayoutArgumentInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal layoutText As String _
)
    Dim equalsPosition As Long = InStr(layoutText, "=")
    Dim commaPosition As Long = InStrRev(layoutText, ",")
    If equalsPosition <= 1 OrElse commaPosition <= equalsPosition + 1 OrElse _
       commaPosition >= Len(layoutText) Then _
        ReportError("static-object layout must have the form CName=FbType,Count")

    Dim sourceName As String = Trim(Left(layoutText, equalsPosition - 1))
    Dim freeBasicType As String = Trim(Mid( _
        layoutText, equalsPosition + 1, commaPosition - equalsPosition - 1))
    Dim countText As String = Trim(Mid(layoutText, commaPosition + 1))
    If IsIdentifierToken(sourceName) = 0 OrElse freeBasicType = "" OrElse _
       countText = "" Then _
        ReportError("static-object layout must have the form CName=FbType,Count")

    Dim arrayCount As Long = 0
    For position As Long = 1 To Len(countText)
        Dim digit As Long = Asc(countText, position) - Asc("0")
        If digit < 0 OrElse digit > 9 OrElse _
           arrayCount > (MAX_GENERIC_ARRAY_COUNT - digit) \ 10 Then _
            ReportError("static-object array count is outside the supported range")
        arrayCount = arrayCount * 10 + digit
    Next
    If arrayCount <= 0 Then _
        ReportError("static-object array count must be positive")

    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        With policy.symbolRenames(renameIndex)
            If .sourceName <> sourceName OrElse _
               .renameNamespace <> C2FB_SYMBOL_RENAME_STATIC_OBJECT_REUSE Then _
                Continue For
            If (.reusedStaticFreeBasicType <> "" AndAlso _
                .reusedStaticFreeBasicType <> freeBasicType) OrElse _
               (.reusedStaticArrayCount <> 0 AndAlso _
                .reusedStaticArrayCount <> arrayCount) Then _
                ReportError("conflicting static-object layout for " & sourceName)
            .reusedStaticFreeBasicType = freeBasicType
            .reusedStaticArrayCount = arrayCount
            Exit Sub
        End With
    Next
    ReportError("static-object layout has no reuse binding for " & sourceName)
End Sub

Private Function GenericFreeBasicTypeNameInPolicy( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, typeNames() As String, ByVal typeNameCount As Long, _
    outputNames() As String, ByVal outputNameCount As Long, _
    ByVal renameNamespace As C2fbSymbolRenameNamespace = _
        C2FB_SYMBOL_RENAME_TYPEDEF, ByVal reusableName As String = "" _
) As String
    Dim result As String = GenericTypeRenameInPolicy( _
        translation.genericC.policy, sourceName, renameNamespace)
    If result = "" Then result = _
        translation.genericC.policy.generatedNamePrefix & sourceName
    ' C and FreeBASIC have separate keyword sets. Keep generated BASIC types
    ' usable when a rename selects a keyword.
    If C2fbFreeBasicIdentifierIsKeyword(result) <> 0 Then result &= "_"

    If translation.genericC.header.rootSourcePath <> "" AndAlso _
       (typeNameCount >= 16 OrElse outputNameCount >= 16) Then
        With translation.genericC.header
            If .typeNameIndex.capacity <= 0 OrElse _
               .typeNameIndexedCount > typeNameCount Then
                ResetC2fbStringIndexMap(.typeNameIndex)
                .typeNameIndexedCount = 0
            End If
            While .typeNameIndexedCount < typeNameCount
                Dim indexedTypeName As String = LCase(typeNames(.typeNameIndexedCount))
                If indexedTypeName <> "" AndAlso AddC2fbStringIndexMapEntry( _
                    .typeNameIndex, indexedTypeName, .typeNameIndexedCount) = 0 Then _
                    ReportError("generic header type-name index exceeds its configured limit")
                .typeNameIndexedCount += 1
            Wend
            If .outputNameIndex.capacity <= 0 OrElse _
               .outputNameIndexedCount > outputNameCount Then
                ResetC2fbStringIndexMap(.outputNameIndex)
                .outputNameIndexedCount = 0
            End If
            While .outputNameIndexedCount < outputNameCount
                Dim indexedOutputName As String = LCase(outputNames(.outputNameIndexedCount))
                If indexedOutputName <> "" AndAlso AddC2fbStringIndexMapEntry( _
                    .outputNameIndex, indexedOutputName, .outputNameIndexedCount) = 0 Then _
                    ReportError("generic header output-name index exceeds its configured limit")
                .outputNameIndexedCount += 1
            Wend
            If result <> reusableName Then
                Do
                    Dim typeConflict As Long = CInt( _
                        C2fbStringIndexMapLookup( _
                            .typeNameIndex, LCase(result)) >= 0)
                    Dim outputConflict As Long = CInt( _
                        C2fbStringIndexMapLookup( _
                            .outputNameIndex, LCase(result)) >= 0)
                    If typeConflict = 0 AndAlso outputConflict = 0 Then Exit Do
                    result &= "_"
                Loop
            End If
            If C2fbStringIndexMapLookup(.typeNameIndex, LCase(result)) < 0 AndAlso _
               AddC2fbStringIndexMapEntry( _
                .typeNameIndex, LCase(result), typeNameCount) = 0 Then _
                ReportError("generic header type-name index exceeds its configured limit")
            If C2fbStringIndexMapLookup(.outputNameIndex, LCase(result)) < 0 AndAlso _
               AddC2fbStringIndexMapEntry( _
                .outputNameIndex, LCase(result), outputNameCount) = 0 Then _
                ReportError("generic header output-name index exceeds its configured limit")
            Return result
        End With
    End If

    Dim conflict As Long
    Do
        conflict = 0
        If result <> reusableName Then _
            conflict = CInt( _
                C2fbNameListContains(typeNames(), typeNameCount, result) <> 0 OrElse _
                C2fbNameListContains(outputNames(), outputNameCount, result) <> 0)
        If conflict <> 0 Then result &= "_"
    Loop While conflict <> 0
    Return result
End Function
/' end of c2fb_generic_policy.bi '/
