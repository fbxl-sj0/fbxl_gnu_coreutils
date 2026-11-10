/'
    Project: C2FB generic header converter

    File: c2fb_generic_include_preservation.bi

    Purpose:

        Preserve selected active C includes as FreeBASIC binding includes.

    Responsibilities:

        - Read active #include directives retained by the C preprocessor.
        - Match caller-supplied C-header to FreeBASIC-include mappings.
        - Add mapped includes and omit their flattened C include subtrees.
        - Stage bounded empty C headers for explicitly mapped missing includes.
        - Keep source selection and include paths in the generic C policy.

    This file intentionally does NOT contain:

        - C include search or preprocessing.
        - FreeBASIC declaration lowering or generic macro translation.
'/

Private Const MAX_C2FB_PRESERVED_INCLUDE_DEPTH As Long = 256
' Keep explicit missing-include stubs bounded per converter invocation.
Private Const MAX_GENERIC_MISSING_INCLUDE_STUBS As Long = 256

Private Function C2fbPreprocessorIncludeName( _
    ByVal directiveText As String, ByRef includeName As String _
) As Long
    includeName = ""
    Dim position As Long = 1
    While position <= Len(directiveText) AndAlso _
          IsSpaceByte(Asc(directiveText, position)) <> 0
        position += 1
    Wend

    Dim directiveWord As String
    While position <= Len(directiveText) AndAlso _
          IsIdentifierPart(Asc(directiveText, position)) <> 0
        directiveWord &= Mid(directiveText, position, 1)
        position += 1
    Wend
    If LCase(directiveWord) <> "include" AndAlso _
       LCase(directiveWord) <> "include_next" Then Return 0
    If position <= Len(directiveText) AndAlso _
       IsSpaceByte(Asc(directiveText, position)) = 0 Then Return 0
    While position <= Len(directiveText) AndAlso _
          IsSpaceByte(Asc(directiveText, position)) <> 0
        position += 1
    Wend
    If position > Len(directiveText) Then Return 0

    Dim closingByte As Long
    Select Case Asc(directiveText, position)
    Case Asc(Chr(34)): closingByte = Asc(Chr(34))
    Case Asc("<"): closingByte = Asc(">")
    Case Else: Return 0
    End Select
    position += 1
    Dim hasClosingDelimiter As Long = 0
    While position <= Len(directiveText)
        Dim currentByte As Long = Asc(directiveText, position)
        If currentByte = closingByte Then
            hasClosingDelimiter = -1
            Exit While
        Else
            includeName &= Chr(currentByte)
        End If
        position += 1
    Wend
    If hasClosingDelimiter = 0 OrElse includeName = "" Then Return 0
    For pathPosition As Long = 1 To Len(includeName)
        If Asc(includeName, pathPosition) = Asc(Chr(92)) Then _
            Mid(includeName, pathPosition, 1) = "/"
    Next
    Return -1
End Function

Private Function C2fbMissingIncludeOperandKind( _
    ByVal includeName As String _
) As Long
    If includeName = "" OrElse Left(includeName, 1) = "/" OrElse _
       InStr(includeName, ":") > 0 Then Return 0
    If InStr(includeName, "*") > 0 OrElse InStr(includeName, "?") > 0 Then _
        Return 2

    Dim componentStart As Long = 1
    For position As Long = 1 To Len(includeName) + 1
        If position <= Len(includeName) Then
            Dim currentByte As Long = Asc(includeName, position)
            If currentByte = Asc("/") Then
                If position = componentStart Then Return 0
            ElseIf currentByte < 32 OrElse currentByte = 127 OrElse _
                   currentByte = Asc(Chr(34)) OrElse _
                   currentByte = Asc("<") OrElse currentByte = Asc(">") OrElse _
                   currentByte = Asc("|") Then
                Return 0
            Else
                Continue For
            End If
        End If

        Dim component As String = Mid( _
            includeName, componentStart, position - componentStart)
        If component = "" OrElse component = "." OrElse component = ".." Then _
            Return 0
        componentStart = position + 1
    Next
    Return -1
End Function

Private Sub RemoveGenericMissingIncludeStubs( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal stubDirectory As String _
)
    If stubDirectory = "" Then Exit Sub

    For mapIndex As Long = 0 To policy.preservedIncludeCount - 1
        Dim includeName As String = _
            policy.preservedIncludes(mapIndex).cHeaderPattern
        If C2fbMissingIncludeOperandKind(includeName) <> -1 Then Continue For
        Dim stubPath As String = stubDirectory & "/" & includeName
        If Dir(stubPath) <> "" Then Kill stubPath
    Next

    For mapIndex As Long = 0 To policy.preservedIncludeCount - 1
        Dim includeName As String = _
            policy.preservedIncludes(mapIndex).cHeaderPattern
        If C2fbMissingIncludeOperandKind(includeName) <> -1 Then Continue For
        Dim separatorPosition As Long = InStrRev(includeName, "/")
        While separatorPosition > 0
            Dim directoryPath As String = stubDirectory & "/" & _
                Left(includeName, separatorPosition - 1)
            If Dir(directoryPath, &H10) <> "" Then RmDir directoryPath
            includeName = Left(includeName, separatorPosition - 1)
            separatorPosition = InStrRev(includeName, "/")
        Wend
    Next
    If Dir(stubDirectory, &H10) <> "" Then RmDir stubDirectory
End Sub

Private Function CreateGenericMissingIncludeStubs( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal stubDirectory As String, _
    ByRef createdStubCount As Long, _
    ByRef failureReason As String _
) As Long
    createdStubCount = 0
    failureReason = ""
    Dim exactMappingCount As Long = 0
    For mapIndex As Long = 0 To policy.preservedIncludeCount - 1
        Dim includeName As String = _
            policy.preservedIncludes(mapIndex).cHeaderPattern
        Dim operandKind As Long = C2fbMissingIncludeOperandKind(includeName)
        If operandKind = 0 Then
            failureReason = "unsafe C include path cannot be used for a temporary stub: " & _
                includeName
            Return 0
        ElseIf operandKind = -1 Then
            exactMappingCount += 1
        End If
    Next
    If exactMappingCount = 0 Then
        failureReason = "at least one exact --preserve-include mapping is required"
        Return 0
    End If
    If exactMappingCount > MAX_GENERIC_MISSING_INCLUDE_STUBS Then
        failureReason = "temporary preserved-include stubs exceed the configured file limit"
        Return 0
    End If
    If MakeDirectoryTree(stubDirectory) = 0 Then
        failureReason = "cannot create temporary preserved-include directory"
        RemoveGenericMissingIncludeStubs(policy, stubDirectory)
        Return 0
    End If

    For mapIndex As Long = 0 To policy.preservedIncludeCount - 1
        Dim includeName As String = _
            policy.preservedIncludes(mapIndex).cHeaderPattern
        If C2fbMissingIncludeOperandKind(includeName) <> -1 Then Continue For
        Dim stubPath As String = stubDirectory & "/" & includeName
        Dim separatorPosition As Long = InStrRev(stubPath, "/")
        If separatorPosition > 0 AndAlso _
           MakeDirectoryTree(Left(stubPath, separatorPosition - 1)) = 0 Then
            failureReason = "cannot create temporary C include directory: " & includeName
            RemoveGenericMissingIncludeStubs(policy, stubDirectory)
            Return 0
        End If
        Dim fileNumber As Long = FreeFile
        If Open(stubPath For Output As #fileNumber) <> 0 Then
            failureReason = "cannot create temporary C include stub: " & includeName
            RemoveGenericMissingIncludeStubs(policy, stubDirectory)
            Return 0
        End If
        Close #fileNumber
        createdStubCount += 1
    Next
    Return -1
End Function

Private Function CPreprocessorLineMarkerHasFlag( _
    ByVal directiveText As String, ByVal requestedFlag As Long _
) As Long
    ' GCC/Clang use flag 1 for entering an included file and flag 2 for return.
    Dim position As Long = 1
    While position <= Len(directiveText) AndAlso _
          IsSpaceByte(Asc(directiveText, position)) <> 0
        position += 1
    Wend
    If LCase(Mid(directiveText, position, 4)) = "line" AndAlso _
       (position + 4 > Len(directiveText) OrElse _
        IsSpaceByte(Asc(directiveText, position + 4)) <> 0) Then
        position += 4
        While position <= Len(directiveText) AndAlso _
              IsSpaceByte(Asc(directiveText, position)) <> 0
            position += 1
        Wend
    End If
    Dim lineDigitCount As Long = 0
    While position <= Len(directiveText) AndAlso _
          Asc(directiveText, position) >= Asc("0") AndAlso _
          Asc(directiveText, position) <= Asc("9")
        lineDigitCount += 1
        position += 1
    Wend
    If lineDigitCount = 0 Then Return 0
    While position <= Len(directiveText) AndAlso _
          IsSpaceByte(Asc(directiveText, position)) <> 0
        position += 1
    Wend
    If position > Len(directiveText) OrElse _
       Asc(directiveText, position) <> Asc(Chr(34)) Then Return 0
    position += 1
    Dim hasClosingQuote As Long = 0
    While position <= Len(directiveText)
        If Asc(directiveText, position) = Asc(Chr(92)) AndAlso _
           position < Len(directiveText) Then
            position += 1
        ElseIf Asc(directiveText, position) = Asc(Chr(34)) Then
            hasClosingQuote = -1
            Exit While
        End If
        position += 1
    Wend
    If hasClosingQuote = 0 Then Return 0
    position += 1

    While position <= Len(directiveText)
        While position <= Len(directiveText) AndAlso _
              IsSpaceByte(Asc(directiveText, position)) <> 0
            position += 1
        Wend
        If position > Len(directiveText) Then Exit While
        Dim tokenStart As Long = position
        While position <= Len(directiveText) AndAlso _
              IsSpaceByte(Asc(directiveText, position)) = 0
            position += 1
        Wend
        Dim markerFlag As Long = Val(Mid(directiveText, tokenStart, position - tokenStart))
        If markerFlag = requestedFlag Then Return -1
    Wend
    Return 0
End Function

Private Function CollectGenericHeaderPreservedIncludes( _
    ByRef translation As C2fbTranslationContext, _
    ByVal preprocessedPath As String, ByVal rootSourcePath As String _
) As Long
    If translation.genericC.policy.preservedIncludeCount = 0 AndAlso _
       translation.genericC.policy.includeRemovalCount = 0 Then Return -1

    Dim lineReader As C2fbLogicalSourceLineReaderModel
    If OpenC2fbLogicalSourceLineReader(lineReader, preprocessedPath) = 0 Then _
        ReportError("cannot read preprocessor include directives: " & preprocessedPath)
    Dim currentSourcePath As String = rootSourcePath
    Dim pendingMapIndex As Long = -1
    Dim includeDepth As Long = 0
    Dim preservedIncludeParentDepths( _
        0 To MAX_C2FB_PRESERVED_INCLUDE_DEPTH - 1) As Long
    Dim preservedIncludeCount As Long = 0
    Dim lineText As String
    Dim firstLine As Long
    Dim wasContinued As Long
    Dim isComplete As Long
    While ReadC2fbLogicalLine( _
        lineReader, lineText, firstLine, wasContinued, isComplete) <> 0
        If isComplete = 0 Then Continue While
        Dim trimmedLine As String = LTrim(lineText)
        If Left(trimmedLine, 1) <> "#" Then Continue While
        Dim directiveText As String = LTrim(Mid(trimmedLine, 2))
        Dim markerLocation As C2fbSourceLocationModel
        If CPreprocessorLineMarkerLocation( _
            directiveText, markerLocation) <> 0 Then
            Dim isIncludeEntry As Long = _
                CPreprocessorLineMarkerHasFlag(directiveText, 1)
            Dim isIncludeReturn As Long = _
                CPreprocessorLineMarkerHasFlag(directiveText, 2)
            If isIncludeEntry <> 0 Then
                If includeDepth >= MAX_C2FB_PRESERVED_INCLUDE_DEPTH Then _
                    ReportError("C include nesting exceeds the preservation limit")
                includeDepth += 1
                If pendingMapIndex >= 0 Then
                    If preservedIncludeCount >= _
                       MAX_C2FB_PRESERVED_INCLUDE_DEPTH Then _
                        ReportError("mapped C include nesting exceeds the preservation limit")
                    preservedIncludeParentDepths(preservedIncludeCount) = _
                        includeDepth - 1
                    preservedIncludeCount += 1
                End If
                Dim includedPath As String = markerLocation.path
                ' The mapped FreeBASIC binding owns every nested C header
                ' expanded beneath this include.
                If preservedIncludeCount > 0 AndAlso includedPath <> "" AndAlso _
                   CSourcePathMatches(rootSourcePath, includedPath) = 0 Then
                    AddGenericSourcePatternInPolicy( _
                        translation.genericC.policy, includedPath, -1, -1)
                End If
                pendingMapIndex = -1
            ElseIf isIncludeReturn <> 0 Then
                If includeDepth <= 0 Then _
                    ReportError("C preprocessor include markers are unbalanced")
                includeDepth -= 1
                While preservedIncludeCount > 0 AndAlso _
                      preservedIncludeParentDepths( _
                        preservedIncludeCount - 1) >= includeDepth
                    preservedIncludeCount -= 1
                Wend
                pendingMapIndex = -1
            End If
            currentSourcePath = markerLocation.path
            Continue While
        End If

        If GenericSourceIncludedForPreservedIncludeInPolicy( _
            translation.genericC.policy, currentSourcePath) = 0 Then
            pendingMapIndex = -1
            Continue While
        End If
        Dim cHeaderName As String
        If C2fbPreprocessorIncludeName(directiveText, cHeaderName) = 0 Then _
            Continue While
        pendingMapIndex = -1
        If GenericIncludeRemovedInPolicy( _
            translation.genericC.policy, cHeaderName) <> 0 Then Continue While
        pendingMapIndex = GenericPreservedIncludeMapIndexInPolicy( _
            translation.genericC.policy, cHeaderName)
        If pendingMapIndex < 0 Then Continue While

        translation.genericC.policy.preservedIncludes( _
            pendingMapIndex).matched = -1
        AddGenericFreeBasicIncludeInPolicy( _
            translation.genericC.policy, _
            translation.genericC.policy.preservedIncludes( _
                pendingMapIndex).freeBasicInclude)
    Wend
    CloseC2fbLogicalSourceLineReader(lineReader)
    Return -1
End Function

/' end of c2fb_generic_include_preservation.bi '/
