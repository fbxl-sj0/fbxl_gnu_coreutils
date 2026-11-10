/'
    Project: C2FB body lowering

    File: c2fb_body_switch.bi

    Purpose:

        Lower supported C switch statements into FreeBASIC control flow.

    Responsibilities:

        - Parse case/default labels and their constant expressions.
        - Track switch-local scopes, break targets, returns, and fallthrough.
        - Emit direct Select Case output or a state machine for fallthrough.
        - Reuse the shared statement and expression lowerers recursively.

    This file intentionally does NOT contain:

        - General statement dispatch or local declaration lowering.
        - C function collection, preprocessing, or procedure signatures.
'/

' Keep switch branch storage within C2FB's per-function workspace bound.
Private Const MAX_SIMPLE_SWITCH_BRANCHES As Long = MAX_FUNCTIONS
' Allocate small initially and grow geometrically for ordinary switches.
Private Const INITIAL_SIMPLE_SWITCH_BRANCH_CAPACITY As Long = 16

Private Function ReadSimpleSwitchCondition( _
    ByRef sourceText As String, _
    ByRef position As Long, _
    ByRef conditionText As String _
) As Long
    SkipCSpaces(sourceText, position)
    If Mid(sourceText, position, 6) <> "switch" Then Return 0
    If position + 6 <= Len(sourceText) AndAlso _
       IsIdentifierPart(Asc(sourceText, position + 6)) <> 0 Then Return 0
    position += 6
    SkipCSpaces(sourceText, position)
    If position > Len(sourceText) OrElse Asc(sourceText, position) <> Asc("(") Then Return 0

    Dim conditionStart As Long = position + 1
    If ScanSimpleExpressionGroup(sourceText, position, Asc("("), Asc(")")) = 0 Then Return 0
    conditionText = Trim(Mid(sourceText, conditionStart, position - conditionStart - 1))
    If Len(conditionText) = 0 Then Return 0
    Return -1
End Function

Private Function IsSimpleSwitchLabel( _
    ByVal sourceText As String, _
    ByVal position As Long _
) As Long
    Dim labelText As String = LTrim(Mid(sourceText, position))
    If Left(labelText, 4) = "case" AndAlso _
       (Len(labelText) = 4 OrElse IsIdentifierPart(Asc(labelText, 5)) = 0) Then Return -1
    If Left(labelText, 7) = "default" AndAlso _
       (Len(labelText) = 7 OrElse IsIdentifierPart(Asc(labelText, 8)) = 0) Then Return -1
    Return 0
End Function

' A C identifier label may prefix a case/default statement. Keep that label
' with the following switch branch so goto enters the same body as in C.
Private Function IsSimpleSwitchLabelPrefix( _
    ByVal sourceText As String, _
    ByVal position As Long _
) As Long
    Dim scanPosition As Long = position
    SkipCSpaces(sourceText, scanPosition)

    While scanPosition <= Len(sourceText)
        If IsIdentifierStart(Asc(sourceText, scanPosition)) = 0 Then Return 0
        Dim labelName As String = ""
        While scanPosition <= Len(sourceText) AndAlso _
              IsIdentifierPart(Asc(sourceText, scanPosition)) <> 0
            labelName &= Mid(sourceText, scanPosition, 1)
            scanPosition += 1
        Wend
        If labelName = "case" OrElse labelName = "default" Then Return 0
        SkipCSpaces(sourceText, scanPosition)
        If scanPosition > Len(sourceText) OrElse _
           Asc(sourceText, scanPosition) <> Asc(":") Then Return 0
        scanPosition += 1
        SkipCSpaces(sourceText, scanPosition)
        If IsSimpleSwitchLabel(sourceText, scanPosition) <> 0 Then Return -1
    Wend
    Return 0
End Function

' A standalone C label inside a switch is a goto target, not a dispatch case.
Private Function IsSimpleStandaloneSwitchLabel( _
    ByVal sourceText As String, _
    ByVal position As Long _
) As Long
    Dim scanPosition As Long = position
    SkipCSpaces(sourceText, scanPosition)
    If scanPosition > Len(sourceText) OrElse _
       IsIdentifierStart(Asc(sourceText, scanPosition)) = 0 Then Return 0

    Dim labelName As String = ""
    While scanPosition <= Len(sourceText) AndAlso _
          IsIdentifierPart(Asc(sourceText, scanPosition)) <> 0
        labelName &= Mid(sourceText, scanPosition, 1)
        scanPosition += 1
    Wend
    If labelName = "case" OrElse labelName = "default" Then Return 0

    SkipCSpaces(sourceText, scanPosition)
    If scanPosition > Len(sourceText) OrElse _
       Asc(sourceText, scanPosition) <> Asc(":") Then Return 0
    Return -1
End Function

' Callback declarations are hoisted into procedure storage by the declaration
' lowerer. Their annotation is only a marker for an uninitialized declaration,
' so it is safe to retain alongside ordinary switch-preamble declarations.
Private Function IsSimpleSwitchStorageAnnotation( _
    ByVal statementText As String _
) As Long
    Select Case Trim(statementText)
    Case "' C automatic storage declaration", _
         "' C automatic callback storage declaration", _
         "' C static callback storage"
        Return -1
    End Select
    Return 0
End Function

Private Function ReadSimpleSwitchLabel( _
    ByRef sourceText As String, _
    ByRef position As Long, _
    ByRef isDefault As Long, _
    ByRef caseExpression As String _
) As Long
    SkipCSpaces(sourceText, position)
    isDefault = 0
    caseExpression = ""
    If Mid(sourceText, position, 7) = "default" AndAlso _
       (position + 7 > Len(sourceText) OrElse _
        IsIdentifierPart(Asc(sourceText, position + 7)) = 0) Then
        position += 7
        SkipCSpaces(sourceText, position)
        If position > Len(sourceText) OrElse Asc(sourceText, position) <> Asc(":") Then Return 0
        position += 1
        isDefault = -1
        Return -1
    End If
    If Mid(sourceText, position, 4) <> "case" OrElse _
       (position + 4 <= Len(sourceText) AndAlso _
        IsIdentifierPart(Asc(sourceText, position + 4)) <> 0) Then Return 0

    position += 4
    Dim expressionStart As Long = position
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim quote As Long = 0
    Dim escaped As Long = 0
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If quote <> 0 Then
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quote Then
                quote = 0
            End If
        ElseIf currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quote = currentByte
        ElseIf currentByte = Asc("(") Then
            parenDepth += 1
        ElseIf currentByte = Asc(")") Then
            parenDepth -= 1
            If parenDepth < 0 Then Return 0
        ElseIf currentByte = Asc("[") Then
            bracketDepth += 1
        ElseIf currentByte = Asc("]") Then
            bracketDepth -= 1
            If bracketDepth < 0 Then Return 0
        ElseIf currentByte = Asc(":") AndAlso parenDepth = 0 AndAlso bracketDepth = 0 Then
            caseExpression = Trim(Mid(sourceText, expressionStart, position - expressionStart))
            If Len(caseExpression) = 0 Then Return 0
            position += 1
            Return -1
        ElseIf (currentByte = Asc(";") OrElse currentByte = Asc("{")) AndAlso _
               parenDepth = 0 AndAlso bracketDepth = 0 Then
            Return 0
        End If
        position += 1
    Wend
    Return 0
End Function

Private Function ReadSimpleBreak( _
    ByRef sourceText As String, _
    ByRef position As Long _
) As Long
    SkipCSpaces(sourceText, position)
    If Mid(sourceText, position, 5) <> "break" OrElse _
       (position + 5 <= Len(sourceText) AndAlso _
        IsIdentifierPart(Asc(sourceText, position + 5)) <> 0) Then Return 0
    position += 5
    SkipCSpaces(sourceText, position)
    If position > Len(sourceText) OrElse Asc(sourceText, position) <> Asc(";") Then Return 0
    position += 1
    Return -1
End Function

Private Function ReportSimpleSwitchFailure( _
    ByRef context As SimpleBodyContext, _
    ByRef sourceText As String, ByVal position As Long _
) As Long
    RecordSimpleBodyFailure( _
        context, "unsupported-switch-statement", _
        "switch parse failure near: " & Left(Mid(sourceText, position), 160))
    Return 0
End Function

Private Function ParseSimpleSwitchStatement( _
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
    Dim parsePosition As Long = position
    Dim conditionText As String
    If ReadSimpleSwitchCondition(sourceText, parsePosition, conditionText) = 0 Then Return 0

    Dim translatedCondition As String
    Dim conditionPrelude As String
    If TranslateSequencedExpression(translation, catalog, _
                                    conditionText, translatedCondition, conditionPrelude, context, _
                                    callableNames(), callableCount, parameterNames(), _
                                    parameterAliases(), parameterTypes(), symbolCount) = 0 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
    SkipCSpaces(sourceText, parsePosition)
    If parsePosition > Len(sourceText) OrElse _
       Asc(sourceText, parsePosition) <> Asc("{") Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
    parsePosition += 1
    Dim breakLabel As String = NewSimpleFlowLabel(context)
    If PushSimpleControlFrame(context, breakLabel, "", -1) = 0 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
    If PushSimpleBodyScope(context, symbolCount, localCount) = 0 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
    Dim switchFrameIndex As Long = context.frameCount - 1

    Dim caseBodies() As String
    Dim branchValues() As String
    Dim branchBodies() As String
    Dim branchReturnFlags() As Long
    Dim branchFallthrough() As Long
    Dim caseCapacity As Long = INITIAL_SIMPLE_SWITCH_BRANCH_CAPACITY
    Dim branchCapacity As Long = INITIAL_SIMPLE_SWITCH_BRANCH_CAPACITY
    ReDim caseBodies(0 To caseCapacity - 1)
    ReDim branchValues(0 To branchCapacity - 1)
    ReDim branchBodies(0 To branchCapacity - 1)
    ReDim branchReturnFlags(0 To branchCapacity - 1)
    ReDim branchFallthrough(0 To branchCapacity - 1)
    Dim caseCount As Long = 0
    Dim branchCount As Long = 0
    Dim defaultBranchIndex As Long = -1
    Dim defaultBody As String = ""
    Dim hasDefault As Long = 0
    Dim hasFallthrough As Long = 0
    Dim sawClosingBrace As Long = 0
    Dim switchPreamble As String = ""

    ' A C switch may declare locals before its first case label. The switch
    ' jump skips this location at runtime, so only declarations with no
    ' emitted statements are safe to hoist into the FreeBASIC procedure scope.
    While parsePosition <= Len(sourceText)
        SkipCSpaces(sourceText, parsePosition)
        If parsePosition > Len(sourceText) Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
        If Asc(sourceText, parsePosition) = Asc("}") OrElse _
           IsSimpleSwitchLabel(sourceText, parsePosition) <> 0 OrElse _
           IsSimpleSwitchLabelPrefix(sourceText, parsePosition) <> 0 OrElse _
           IsSimpleStandaloneSwitchLabel(sourceText, parsePosition) <> 0 Then Exit While
        If Asc(sourceText, parsePosition) = Asc(";") Then
            parsePosition += 1
            Continue While
        End If

        Dim preambleText As String = ""
        Dim preambleTerminates As Long = 0
        If ParseSimpleCStatement(translation, catalog, sourceText, parsePosition, _
                                 preambleText, indentText, returnType, context, _
                                 callableNames(), callableCount, parameterNames(), _
                                 parameterAliases(), parameterTypes(), symbolCount, _
                                 locals(), localCount, preambleTerminates) = 0 Then
            RecordSimpleBodyFailure( _
                context, "unsupported-switch-preamble-declaration", _
                "could not translate switch preamble: " & _
                Left(Mid(sourceText, parsePosition), 160))
            Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
        End If
        Dim preambleLine As String = Trim(preambleText)
        If preambleTerminates <> 0 OrElse context.branchJump <> 0 Then _
            Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
        If preambleLine <> "" Then
            If preambleLine <> "' C nested switch-case scope" AndAlso _
               IsSimpleSwitchStorageAnnotation(preambleLine) = 0 AndAlso _
               (Left(LCase(preambleLine), 4) <> "dim " OrElse _
                InStr(preambleLine, "=") <> 0 OrElse _
                InStr(preambleLine, "(") <> 0) Then _
                Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
            If switchPreamble <> "" Then switchPreamble &= Chr(10)
            switchPreamble &= indentText & preambleLine
        End If
    Wend

    While parsePosition <= Len(sourceText)
        SkipCSpaces(sourceText, parsePosition)
        If parsePosition > Len(sourceText) Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
        If Asc(sourceText, parsePosition) = Asc("}") Then
            If context.frames(switchFrameIndex).nestedCaseBlockDepth > 0 Then
                parsePosition += 1
                context.frames(switchFrameIndex).nestedCaseBlockDepth -= 1
                PopSimpleBodyScope(context, symbolCount, localCount)
                Continue While
            End If
            parsePosition += 1
            sawClosingBrace = -1
            Exit While
        End If

        If Asc(sourceText, parsePosition) = Asc("{") AndAlso _
           SimpleBlockContainsSwitchLabel(sourceText, parsePosition) <> 0 Then
            Dim blockPreambleText As String = ""
            Dim blockPreambleTerminates As Long = 0
            If ParseSimpleCStatement( _
                translation, catalog, sourceText, parsePosition, _
                blockPreambleText, indentText, returnType, context, _
                callableNames(), callableCount, parameterNames(), _
                parameterAliases(), parameterTypes(), symbolCount, locals(), _
                localCount, blockPreambleTerminates) = 0 OrElse _
               blockPreambleTerminates <> 0 OrElse context.branchJump <> 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-switch-case-block", _
                    "could not translate nested switch-case block: " & _
                    Left(Mid(sourceText, parsePosition), 160))
                Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
            End If
            Dim blockPreambleLine As String = Trim(blockPreambleText)
            If blockPreambleLine <> "" Then
                If blockPreambleLine <> "' C nested switch-case scope" AndAlso _
                   IsSimpleSwitchStorageAnnotation(blockPreambleLine) = 0 AndAlso _
                   (Left(LCase(blockPreambleLine), 4) <> "dim " OrElse _
                    InStr(blockPreambleLine, "=") <> 0 OrElse _
                    InStr(blockPreambleLine, "(") <> 0) Then _
                    Return ReportSimpleSwitchFailure( _
                        context, sourceText, parsePosition)
                If switchPreamble <> "" Then switchPreamble &= Chr(10)
                switchPreamble &= indentText & blockPreambleLine
            End If

            While parsePosition <= Len(sourceText)
                SkipCSpaces(sourceText, parsePosition)
                If parsePosition > Len(sourceText) OrElse _
                   Asc(sourceText, parsePosition) = Asc("}") OrElse _
                   IsSimpleSwitchLabel(sourceText, parsePosition) <> 0 OrElse _
                   IsSimpleSwitchLabelPrefix(sourceText, parsePosition) <> 0 Then _
                    Exit While
                If Asc(sourceText, parsePosition) = Asc(";") Then
                    parsePosition += 1
                    Continue While
                End If
                blockPreambleText = ""
                blockPreambleTerminates = 0
                If ParseSimpleCStatement( _
                    translation, catalog, sourceText, parsePosition, _
                    blockPreambleText, indentText, returnType, context, _
                    callableNames(), callableCount, parameterNames(), _
                    parameterAliases(), parameterTypes(), symbolCount, locals(), _
                    localCount, blockPreambleTerminates) = 0 OrElse _
                   blockPreambleTerminates <> 0 OrElse context.branchJump <> 0 Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-switch-case-block-preamble", _
                        "could not translate nested switch-case declaration: " & _
                        Left(Mid(sourceText, parsePosition), 160))
                    Return ReportSimpleSwitchFailure( _
                        context, sourceText, parsePosition)
                End If
                blockPreambleLine = Trim(blockPreambleText)
                If blockPreambleLine <> "" Then
                    If blockPreambleLine <> "' C nested switch-case scope" AndAlso _
                       IsSimpleSwitchStorageAnnotation(blockPreambleLine) = 0 AndAlso _
                       (Left(LCase(blockPreambleLine), 4) <> "dim " OrElse _
                        InStr(blockPreambleLine, "=") <> 0 OrElse _
                        InStr(blockPreambleLine, "(") <> 0) Then _
                        Return ReportSimpleSwitchFailure( _
                            context, sourceText, parsePosition)
                    If switchPreamble <> "" Then switchPreamble &= Chr(10)
                    switchPreamble &= indentText & blockPreambleLine
                End If
            Wend
            Continue While
        End If

        Dim branchLabelPrefix As String = ""
        While IsSimpleSwitchLabelPrefix(sourceText, parsePosition) <> 0
            Dim labelText As String
            Dim labelTerminates As Long = 0
            If ParseSimpleCStatement( _
                translation, catalog, sourceText, parsePosition, labelText, _
                indentText & "        ", returnType, context, _
                callableNames(), callableCount, parameterNames(), _
                parameterAliases(), parameterTypes(), symbolCount, locals(), _
                localCount, labelTerminates) = 0 OrElse labelTerminates <> 0 Then _
                Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
            If branchLabelPrefix <> "" Then _
                branchLabelPrefix &= Chr(10)
            branchLabelPrefix &= labelText
            SkipCSpaces(sourceText, parsePosition)
        Wend

        Dim isGotoLabelBranch As Long = 0
        While IsSimpleStandaloneSwitchLabel(sourceText, parsePosition) <> 0
            Dim labelText As String
            Dim labelTerminates As Long = 0
            If ParseSimpleCStatement( _
                translation, catalog, sourceText, parsePosition, labelText, _
                indentText & "        ", returnType, context, _
                callableNames(), callableCount, parameterNames(), _
                parameterAliases(), parameterTypes(), symbolCount, locals(), _
                localCount, labelTerminates) = 0 OrElse labelTerminates <> 0 Then _
                Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
            If branchLabelPrefix <> "" Then branchLabelPrefix &= Chr(10)
            branchLabelPrefix &= labelText
            isGotoLabelBranch = -1
            SkipCSpaces(sourceText, parsePosition)
        Wend

        Dim caseValues As String = ""
        Dim castCaseValues As String = ""
        Dim isDefaultGroup As Long = 0
        While IsSimpleSwitchLabel(sourceText, parsePosition) <> 0
            Dim labelIsDefault As Long = 0
            Dim caseExpression As String = ""
            If ReadSimpleSwitchLabel(sourceText, parsePosition, _
                                     labelIsDefault, caseExpression) = 0 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
            If labelIsDefault <> 0 Then
                If isDefaultGroup <> 0 OrElse hasDefault <> 0 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
                isDefaultGroup = -1
            Else
                Dim translatedCase As String
                Dim caseHasBoolean As Long = 0
                Dim caseHasCall As Long = 0
                If TranslateSimpleExpression(translation, catalog, _
                                             caseExpression, translatedCase, _
                                             caseHasBoolean, caseHasCall, _
                                             callableNames(), callableCount, parameterNames(), _
                                             parameterAliases(), parameterTypes(), symbolCount) = 0 OrElse _
                   caseHasCall <> 0 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
                If Len(caseValues) <> 0 Then caseValues &= ", "
                caseValues &= translatedCase
                If Len(castCaseValues) <> 0 Then castCaseValues &= ", "
                castCaseValues &= "Cast(c2fb_uint64, " & translatedCase & ")"
            End If
            SkipCSpaces(sourceText, parsePosition)
        Wend
        If isDefaultGroup = 0 AndAlso Len(caseValues) = 0 AndAlso _
           isGotoLabelBranch = 0 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
        If isDefaultGroup <> 0 AndAlso Len(caseValues) <> 0 Then
            ' Both the matching labels and the unmatched path enter one body.
            ' Use the state-machine form so generated labels in that body are
            ' emitted once rather than duplicated in Case and Case Else.
            hasFallthrough = -1
        End If
        If isGotoLabelBranch <> 0 Then hasFallthrough = -1

        Dim branchBody As String = branchLabelPrefix
        Dim branchReturns As Long = 0
        Dim branchBreaks As Long = 0
        Dim branchStatementCount As Long = 0
        While parsePosition <= Len(sourceText)
            SkipCSpaces(sourceText, parsePosition)
            If parsePosition > Len(sourceText) Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
            If Asc(sourceText, parsePosition) = Asc("}") OrElse _
               IsSimpleSwitchLabel(sourceText, parsePosition) <> 0 OrElse _
               IsSimpleSwitchLabelPrefix(sourceText, parsePosition) <> 0 Then Exit While

            Dim returnPosition As Long = parsePosition
            Dim returnExpression As String
            If ReadSimpleReturn(sourceText, returnPosition, returnExpression) <> 0 Then
                Dim translatedReturn As String
                Dim returnPrelude As String
                If TranslateSimpleReturnValue(translation, catalog, returnType, returnExpression, translatedReturn, returnPrelude, context, _
                                              callableNames(), callableCount, parameterNames(), _
                                              parameterAliases(), parameterTypes(), symbolCount) = 0 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
                Dim returnText As String = ""
                If returnPrelude <> "" Then returnText = IndentSimpleBodyText(RTrim(returnPrelude, Any Chr(10)), indentText & "        ") & Chr(10)
                returnText &= indentText & "        Return"
                If Len(translatedReturn) <> 0 Then returnText &= " " & translatedReturn
                branchBody &= IIf(Len(branchBody) = 0, "", Chr(10)) & returnText
                parsePosition = returnPosition
                branchReturns = -1
                Exit While
            End If

            If ReadSimpleBreak(sourceText, parsePosition) <> 0 Then
                branchBreaks = -1
                Exit While
            End If

            Dim statementText As String
            Dim statementTerminates As Long = 0
            If ParseSimpleCStatement(translation, catalog, sourceText, parsePosition, statementText, _
                                     indentText & "        ", returnType, context, _
                                     callableNames(), callableCount, parameterNames(), _
                                     parameterAliases(), parameterTypes(), symbolCount, locals(), localCount, _
                                     statementTerminates) = 0 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
            branchBody &= IIf(Len(branchBody) = 0, "", Chr(10)) & statementText
            branchStatementCount += 1
            If statementTerminates <> 0 Then
                branchReturns = -1
            ElseIf context.branchJump <> 0 Then
                branchBreaks = -1
                If Left(LCase(LTrim(statementText)), 5) = "goto " Then
                    ' Keep parsing the branch so a following in-switch label
                    ' can receive gotos from earlier case groups.
                    context.branchJump = 0
                    Continue While
                End If
                Exit While
            End If
        Wend

        SkipCSpaces(sourceText, parsePosition)
        ' A case body may be a compound statement followed by an empty statement.
        While parsePosition <= Len(sourceText) AndAlso _
              Asc(sourceText, parsePosition) = Asc(";")
            parsePosition += 1
            SkipCSpaces(sourceText, parsePosition)
        Wend
        If parsePosition <= Len(sourceText) AndAlso _
           Asc(sourceText, parsePosition) <> Asc("}") AndAlso _
           IsSimpleSwitchLabel(sourceText, parsePosition) = 0 AndAlso _
           IsSimpleSwitchLabelPrefix(sourceText, parsePosition) = 0 AndAlso _
           IsSimpleStandaloneSwitchLabel(sourceText, parsePosition) = 0 Then
            If Asc(sourceText, parsePosition) <> Asc("{") OrElse _
               SimpleBlockContainsSwitchLabel( _
                   sourceText, parsePosition) = 0 Then _
                Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)

            ' C permits case labels inside a compound block between switch
            ' groups. Hoist only uninitialized declarations that precede the
            ' first nested label; their storage is function-scoped in C2FB.
            Dim preambleText As String
            Dim preambleTerminates As Long = 0
            If ParseSimpleCStatement( _
                translation, catalog, sourceText, parsePosition, _
                preambleText, indentText, returnType, context, _
                callableNames(), callableCount, parameterNames(), _
                parameterAliases(), parameterTypes(), symbolCount, locals(), _
                localCount, preambleTerminates) = 0 OrElse _
               preambleTerminates <> 0 OrElse context.branchJump <> 0 Then
                RecordSimpleBodyFailure( _
                    context, "unsupported-switch-case-preamble", _
                    "could not translate nested switch preamble: " & _
                    Left(Mid(sourceText, parsePosition), 160))
                Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
            End If
            Dim preambleLine As String = Trim(preambleText)
            If preambleLine <> "" Then
                If preambleLine <> "' C nested switch-case scope" AndAlso _
                   IsSimpleSwitchStorageAnnotation(preambleLine) = 0 AndAlso _
                    (Left(LCase(preambleLine), 4) <> "dim " OrElse _
                     InStr(preambleLine, "=") <> 0 OrElse _
                    InStr(preambleLine, "(") <> 0) Then _
                    Return ReportSimpleSwitchFailure( _
                        context, sourceText, parsePosition)
                If switchPreamble <> "" Then switchPreamble &= Chr(10)
                switchPreamble &= indentText & preambleLine
            End If

            While parsePosition <= Len(sourceText)
                SkipCSpaces(sourceText, parsePosition)
                If parsePosition > Len(sourceText) OrElse _
                   Asc(sourceText, parsePosition) = Asc("}") OrElse _
                   IsSimpleSwitchLabel(sourceText, parsePosition) <> 0 OrElse _
                   IsSimpleSwitchLabelPrefix(sourceText, parsePosition) <> 0 Then _
                    Exit While
                If Asc(sourceText, parsePosition) = Asc(";") Then
                    parsePosition += 1
                    Continue While
                End If
                preambleText = ""
                preambleTerminates = 0
                If ParseSimpleCStatement( _
                    translation, catalog, sourceText, parsePosition, _
                    preambleText, indentText, returnType, context, _
                    callableNames(), callableCount, parameterNames(), _
                    parameterAliases(), parameterTypes(), symbolCount, locals(), _
                    localCount, preambleTerminates) = 0 OrElse _
                   preambleTerminates <> 0 OrElse context.branchJump <> 0 Then
                    RecordSimpleBodyFailure( _
                        context, "unsupported-nested-switch-preamble", _
                        "could not translate nested switch declaration: " & _
                        Left(Mid(sourceText, parsePosition), 160))
                    Return ReportSimpleSwitchFailure( _
                        context, sourceText, parsePosition)
                End If
                preambleLine = Trim(preambleText)
                If preambleLine <> "" Then
                    If preambleLine <> "' C nested switch-case scope" AndAlso _
                       IsSimpleSwitchStorageAnnotation(preambleLine) = 0 AndAlso _
                       (Left(LCase(preambleLine), 4) <> "dim " OrElse _
                        InStr(preambleLine, "=") <> 0 OrElse _
                        InStr(preambleLine, "(") <> 0) Then _
                        Return ReportSimpleSwitchFailure( _
                            context, sourceText, parsePosition)
                    If switchPreamble <> "" Then switchPreamble &= Chr(10)
                    switchPreamble &= indentText & preambleLine
                End If
            Wend
        End If
        If parsePosition <= Len(sourceText) AndAlso _
           Asc(sourceText, parsePosition) <> Asc("}") AndAlso _
           IsSimpleSwitchLabel(sourceText, parsePosition) = 0 AndAlso _
           IsSimpleSwitchLabelPrefix(sourceText, parsePosition) = 0 AndAlso _
           IsSimpleStandaloneSwitchLabel(sourceText, parsePosition) = 0 Then _
            Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
        Dim fallsThrough As Long = 0
        If (IsSimpleSwitchLabel(sourceText, parsePosition) <> 0 OrElse _
            IsSimpleSwitchLabelPrefix(sourceText, parsePosition) <> 0 OrElse _
            IsSimpleStandaloneSwitchLabel(sourceText, parsePosition) <> 0) AndAlso _
           branchReturns = 0 AndAlso branchBreaks = 0 Then
            fallsThrough = -1
            hasFallthrough = -1
        End If

        If branchCount >= MAX_SIMPLE_SWITCH_BRANCHES Then _
            Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
        If branchCount >= branchCapacity Then
            Dim newBranchCapacity As Long = branchCapacity * 2
            If newBranchCapacity > MAX_SIMPLE_SWITCH_BRANCHES Then _
                newBranchCapacity = MAX_SIMPLE_SWITCH_BRANCHES
            ReDim Preserve branchValues(0 To newBranchCapacity - 1)
            ReDim Preserve branchBodies(0 To newBranchCapacity - 1)
            ReDim Preserve branchReturnFlags(0 To newBranchCapacity - 1)
            ReDim Preserve branchFallthrough(0 To newBranchCapacity - 1)
            branchCapacity = newBranchCapacity
        End If
        branchValues(branchCount) = castCaseValues
        branchBodies(branchCount) = branchBody
        branchReturnFlags(branchCount) = branchReturns
        branchFallthrough(branchCount) = fallsThrough
        If isDefaultGroup <> 0 Then defaultBranchIndex = branchCount
        branchCount += 1

        If isDefaultGroup <> 0 Then
            hasDefault = -1
            defaultBody = indentText & "    Case Else"
            If Len(branchBody) <> 0 Then defaultBody &= Chr(10) & branchBody
        End If
        If Len(caseValues) <> 0 Then
            If caseCount >= MAX_SIMPLE_SWITCH_BRANCHES Then _
                Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
            If caseCount >= caseCapacity Then
                Dim newCaseCapacity As Long = caseCapacity * 2
                If newCaseCapacity > MAX_SIMPLE_SWITCH_BRANCHES Then _
                    newCaseCapacity = MAX_SIMPLE_SWITCH_BRANCHES
                ReDim Preserve caseBodies(0 To newCaseCapacity - 1)
                caseCapacity = newCaseCapacity
            End If
            caseBodies(caseCount) = indentText & "    Case " & caseValues
            If Len(branchBody) <> 0 Then caseBodies(caseCount) &= Chr(10) & branchBody
            caseCount += 1
        End If
    Wend
    If sawClosingBrace = 0 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
    context.frameCount -= 1
    PopSimpleBodyScope(context, symbolCount, localCount)

    outputText = ""
    If switchPreamble <> "" Then outputText = switchPreamble & Chr(10)
    If conditionPrelude <> "" Then outputText &= IndentSimpleBodyText(RTrim(conditionPrelude, Any Chr(10)), indentText) & Chr(10)
    If hasFallthrough = 0 Then
        outputText &= indentText & "Select Case " & translatedCondition
        For caseIndex As Long = 0 To caseCount - 1
            outputText &= Chr(10) & caseBodies(caseIndex)
        Next
        If hasDefault <> 0 Then outputText &= Chr(10) & defaultBody
        outputText &= Chr(10) & indentText & "End Select"
    Else
        If context.temporarySerial > MAX_FUNCTIONS - 2 Then Return ReportSimpleSwitchFailure(context, sourceText, parsePosition)
        Dim switchValue As String = "c2fb_switch_value_" & Trim(Str(context.temporarySerial))
        Dim switchState As String = "c2fb_switch_state_" & Trim(Str(context.temporarySerial + 1))
        context.temporarySerial += 2
        context.declarations &= "    Dim " & switchValue & " As c2fb_uint64" & Chr(10)
        context.declarations &= "    Dim " & switchState & " As c2fb_c_int" & Chr(10)

        outputText &= indentText & switchValue & " = Cast(c2fb_uint64, " & _
                      translatedCondition & ")" & Chr(10)
        outputText &= indentText & switchState & " = 0" & Chr(10)
        outputText &= indentText & "Select Case " & switchValue
        For branchIndex As Long = 0 To branchCount - 1
            If branchValues(branchIndex) = "" Then Continue For
            outputText &= Chr(10) & indentText & "    Case " & branchValues(branchIndex)
            outputText &= Chr(10) & indentText & "        " & switchState & " = " & _
                          Trim(Str(branchIndex + 1))
        Next
        If defaultBranchIndex >= 0 Then
            outputText &= Chr(10) & indentText & "    Case Else"
            outputText &= Chr(10) & indentText & "        " & switchState & " = " & _
                          Trim(Str(defaultBranchIndex + 1))
        End If
        outputText &= Chr(10) & indentText & "End Select"
        outputText &= Chr(10) & indentText & "Do"
        outputText &= Chr(10) & indentText & "    Select Case " & switchState
        outputText &= Chr(10) & indentText & "    Case 0"
        outputText &= Chr(10) & indentText & "        Exit Do"
        For branchIndex As Long = 0 To branchCount - 1
            outputText &= Chr(10) & indentText & "    Case " & Trim(Str(branchIndex + 1))
            If branchBodies(branchIndex) <> "" Then _
                outputText &= Chr(10) & branchBodies(branchIndex)
            If branchReturnFlags(branchIndex) = 0 Then
                If branchFallthrough(branchIndex) <> 0 Then
                    outputText &= Chr(10) & indentText & "        " & switchState & " = " & _
                                  Trim(Str(branchIndex + 2))
                Else
                    outputText &= Chr(10) & indentText & "        " & switchState & " = 0"
                End If
            End If
        Next
        outputText &= Chr(10) & indentText & "    End Select"
        outputText &= Chr(10) & indentText & "Loop"
    End If
    outputText &= Chr(10) & indentText & breakLabel & ":"
    Dim everySwitchEntryReturns As Long = -1
    If branchCount > 0 Then
        Dim branchTerminates() As Long
        ReDim branchTerminates(0 To branchCount - 1)
        For branchIndex As Long = branchCount - 1 To 0 Step -1
            If branchReturnFlags(branchIndex) <> 0 Then
                branchTerminates(branchIndex) = -1
            ElseIf branchFallthrough(branchIndex) <> 0 AndAlso _
                   branchIndex + 1 < branchCount Then
                branchTerminates(branchIndex) = branchTerminates(branchIndex + 1)
            End If
            If branchTerminates(branchIndex) = 0 Then everySwitchEntryReturns = 0
        Next
    Else
        everySwitchEntryReturns = 0
    End If
    ' A case that falls through returns only when the branch it enters returns.
    ' The default branch must also terminate so unmatched values cannot escape.
    terminatesPaths = CInt( _
        hasDefault <> 0 AndAlso everySwitchEntryReturns <> 0)
    position = parsePosition
    Return -1
End Function

/' end of c2fb_body_switch.bi '/
