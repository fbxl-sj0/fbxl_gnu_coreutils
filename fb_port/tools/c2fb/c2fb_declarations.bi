/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_declarations.bi

    Purpose:

        Build shared C declaration and declarator models for all C2FB modes.

    Responsibilities:

        - Own the common source-located declaration table.
        - Parse pointer, grouped, array, and function declarator operators.
        - Preserve the binding order around parenthesized declarators.
        - Retain function parameter-list positions for nested callback lowering.
        - Skip recognized calling-convention tokens within pointer declarators.
        - Accept a function name only when its identifier binds first to a
          function operator and is not a declaration specifier.
        - Split declarator lists by token range while respecting nested groups.
        - Restore shared specifier tokens for each comma-separated declarator.
        - Retain semicolon-delimited record fields with their declaration tokens.
        - Identify function declarations when ordinary declaration items enter
          the common table.

    This file intentionally does NOT contain:

        - C type conversion, parameter translation, or function-body parsing.
        - Preprocessor evaluation or a complete ISO C grammar.
'/

Private Function SkipCDeclaratorGroup( _
    tokens() As String, ByRef position As Long, ByVal lastToken As Long, _
    ByVal openingToken As String, ByVal closingToken As String _
) As Long
    If position > lastToken OrElse tokens(position) <> openingToken Then Return 0
    Dim nesting As Long = 0
    While position <= lastToken
        If tokens(position) = openingToken Then
            nesting += 1
        ElseIf tokens(position) = closingToken Then
            nesting -= 1
            position += 1
            If nesting = 0 Then Return -1
            Continue While
        End If
        position += 1
    Wend
    Return 0
End Function

Private Function IsCDeclaratorCallingConventionToken( _
    ByVal token As String _
) As Long
    Select Case LCase(token)
    Case "cdecl", "__cdecl", "__cdecl__", "stdcall", "__stdcall", _
         "__stdcall__", "winapi", "apientry", "ntapi"
        Return -1
    End Select
    Return 0
End Function

Private Function ParseCDeclaratorRecursive( _
    tokens() As String, ByRef position As Long, ByVal lastToken As Long, _
    ByRef declaratorName As String, ByRef bindingOrder As String, _
    ByRef nameTokenIndex As Long, ByRef functionOpenToken As Long, _
    ByRef functionOpenPositions As String, _
    ByVal depth As Long, ByVal allowAbstract As Long _
) As Long
    ' C declarators bind outward from the identifier. A suffix belongs to the
    ' direct declarator before its pointer prefixes, which is why `*f()` is a
    ' function returning a pointer while `(*f)()` is a pointer to a function.
    If depth >= 64 Then Return 0

    Dim pointerCount As Long = 0
    While position <= lastToken
        If IsCDeclaratorCallingConventionToken(tokens(position)) <> 0 Then
            position += 1
            Continue While
        End If
        If tokens(position) <> "*" Then Exit While
        pointerCount += 1
        position += 1
        While position <= lastToken
            Select Case tokens(position)
            Case "const", "volatile", "restrict", "__restrict", "__restrict__"
                position += 1
            Case "cdecl", "__cdecl", "__cdecl__", "stdcall", "__stdcall", _
                 "__stdcall__", "winapi", "apientry", "ntapi"
                position += 1
            Case Else
                Exit While
            End Select
        Wend
    Wend

    Dim directBinding As String
    Dim directFunctionOpenPositions As String
    nameTokenIndex = -1
    functionOpenToken = -1
    If position <= lastToken AndAlso tokens(position) = "(" Then
        position += 1
        If ParseCDeclaratorRecursive(tokens(), position, lastToken, declaratorName, _
                            directBinding, nameTokenIndex, functionOpenToken, _
                            directFunctionOpenPositions, _
                            depth + 1, allowAbstract) = 0 Then Return 0
        If position > lastToken OrElse tokens(position) <> ")" Then Return 0
        position += 1
    ElseIf position <= lastToken AndAlso IsIdentifierToken(tokens(position)) <> 0 Then
        declaratorName = tokens(position)
        nameTokenIndex = position
        position += 1
    ElseIf allowAbstract <> 0 AndAlso _
           (position > lastToken OrElse tokens(position) = ")" OrElse _
            tokens(position) = "(" OrElse tokens(position) = "[") Then
        ' Abstract declarators omit the identifier, as in `int (*)(int)`.
        declaratorName = ""
        nameTokenIndex = -1
    Else
        Return 0
    End If

    While position <= lastToken
        Select Case tokens(position)
        Case "("
            If functionOpenToken < 0 Then functionOpenToken = position
            directFunctionOpenPositions &= Chr(position + 1)
            If SkipCDeclaratorGroup(tokens(), position, lastToken, "(", ")") = 0 Then Return 0
            directBinding &= "F"
        Case "["
            If SkipCDeclaratorGroup(tokens(), position, lastToken, "[", "]") = 0 Then Return 0
            directBinding &= "A"
        Case Else
            Exit While
        End Select
    Wend

    For pointerIndex As Long = 1 To pointerCount
        directBinding &= "P"
    Next
    bindingOrder = directBinding
    functionOpenPositions = directFunctionOpenPositions
    Return -1
End Function

Private Function ParseCDeclaratorModel( _
    tokens() As String, ByRef position As Long, ByVal lastToken As Long, _
    ByRef declarator As C2fbDeclaratorModel, ByVal depth As Long, _
    ByVal allowAbstract As Long _
) As Long
    declarator.name = ""
    declarator.bindingOrder = ""
    declarator.functionOpenPositions = ""
    declarator.nameTokenIndex = -1
    declarator.firstFunctionOpenToken = -1
    declarator.firstToken = position
    declarator.nextToken = position
    declarator.operatorCount = 0

    Dim declaratorName As String
    Dim bindingOrder As String
    Dim nameTokenIndex As Long = -1
    Dim functionOpenToken As Long = -1
    Dim functionOpenPositions As String
    If ParseCDeclaratorRecursive( _
        tokens(), position, lastToken, declaratorName, bindingOrder, _
        nameTokenIndex, functionOpenToken, functionOpenPositions, _
        depth, allowAbstract) = 0 Then Return 0

    declarator.name = declaratorName
    declarator.bindingOrder = bindingOrder
    declarator.functionOpenPositions = functionOpenPositions
    declarator.nameTokenIndex = nameTokenIndex
    declarator.firstFunctionOpenToken = functionOpenToken
    declarator.nextToken = position
    For bindingIndex As Long = 1 To Len(bindingOrder)
        If declarator.operatorCount >= UBound(declarator.operatorKind) Then Return 0
        Select Case Mid(bindingOrder, bindingIndex, 1)
        Case "P": declarator.operatorKind(declarator.operatorCount) = C2FB_DECLARATOR_POINTER
        Case "A": declarator.operatorKind(declarator.operatorCount) = C2FB_DECLARATOR_ARRAY
        Case "F": declarator.operatorKind(declarator.operatorCount) = C2FB_DECLARATOR_FUNCTION
        Case Else: Return 0
        End Select
        declarator.operatorCount += 1
    Next
    Return -1
End Function

Private Function IsCFunctionReturnTypePrefix( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long _
) As Long
    If firstToken > lastToken Then Return 0
    Dim foundType As Long = 0
    Dim tokenIndex As Long = firstToken
    While tokenIndex <= lastToken
        If IsIdentifierToken(tokens(tokenIndex)) = 0 Then Return 0
        If tokens(tokenIndex) = "_Atomic" AndAlso _
           tokenIndex < lastToken AndAlso tokens(tokenIndex + 1) = "(" Then
            ' Treat the wrapped type-name as one declaration specifier here.
            ' ParseCTypeModel normalizes the wrapper when resolving its type.
            Dim nestingDepth As Long = 1
            Dim closingToken As Long = tokenIndex + 2
            While closingToken <= lastToken AndAlso nestingDepth > 0
                If tokens(closingToken) = "(" Then
                    nestingDepth += 1
                ElseIf tokens(closingToken) = ")" Then
                    nestingDepth -= 1
                End If
                If nestingDepth > 0 Then closingToken += 1
            Wend
            If nestingDepth <> 0 OrElse closingToken = tokenIndex + 2 Then _
                Return 0
            foundType = -1
            tokenIndex = closingToken + 1
            Continue While
        End If
        Select Case tokens(tokenIndex)
        Case "auto", "extern", "inline", "__inline", "__inline__", _
             "register", "static", "typedef", _
             "const", "volatile", "restrict", "_Noreturn", "__thread", _
             "_Thread_local", "thread_local", _
             "__restrict", "__restrict__", "struct", "union", "enum"
            tokenIndex += 1
            Continue While
        End Select
        If IsAttributeToken(tokens(tokenIndex)) <> 0 Then
            tokenIndex += 1
            Continue While
        End If
        ' Unknown identifiers can be typedef names. Treating them as type
        ' specifiers lets the name finder work across projects whose private
        ' type catalog is not available to C2FB.
        foundType = -1
        tokenIndex += 1
    Wend
    Return foundType
End Function

Private Function ParseCFunctionDeclarationModel( _
    tokens() As String, ByVal tokenCount As Long, _
    ByRef declaration As C2fbFunctionDeclarationModel, _
    ByVal allowDefaultArguments As Long = 0 _
) As Long
    declaration.declaratorStartToken = -1
    declaration.specifierEndToken = -1
    If tokenCount < 3 OrElse tokenCount >= MAX_TYPE_WORDS Then Return 0

    Dim lastToken As Long = tokenCount - 1
    If tokens(lastToken) = ";" Then lastToken -= 1
    For tokenIndex As Long = 0 To lastToken
        If tokens(tokenIndex) = "typedef" Then Return 0
        If allowDefaultArguments = 0 AndAlso tokens(tokenIndex) = "=" Then _
            Return 0
    Next

    For candidateStart As Long = 1 To lastToken
        Dim candidateInsideAtomicType As Long = 0
        Dim atomicSpecifier As Long = 0
        While atomicSpecifier <= candidateStart
            If tokens(atomicSpecifier) = "_Atomic" AndAlso _
               atomicSpecifier < lastToken AndAlso _
               tokens(atomicSpecifier + 1) = "(" Then
                Dim nestingDepth As Long = 1
                Dim closingToken As Long = atomicSpecifier + 2
                While closingToken <= lastToken AndAlso nestingDepth > 0
                    If tokens(closingToken) = "(" Then
                        nestingDepth += 1
                    ElseIf tokens(closingToken) = ")" Then
                        nestingDepth -= 1
                    End If
                    If nestingDepth > 0 Then closingToken += 1
                Wend
                If nestingDepth <> 0 Then Return 0
                If candidateStart >= atomicSpecifier AndAlso _
                   candidateStart <= closingToken Then
                    candidateInsideAtomicType = -1
                    Exit While
                End If
                atomicSpecifier = closingToken + 1
            Else
                atomicSpecifier += 1
            End If
        Wend
        If candidateInsideAtomicType <> 0 Then Continue For
        If IsCFunctionReturnTypePrefix(tokens(), 0, candidateStart - 1) = 0 Then Continue For
        Dim position As Long = candidateStart
        Dim candidate As C2fbDeclaratorModel
        If ParseCDeclaratorModel( _
            tokens(), position, lastToken, candidate, 0, 0) = 0 Then Continue For
        If position <= lastToken AndAlso tokens(position) = ";" Then position += 1
        If position <> lastToken + 1 OrElse Len(candidate.bindingOrder) = 0 OrElse _
           Left(candidate.bindingOrder, 1) <> "F" OrElse _
           candidate.firstFunctionOpenToken < 0 Then Continue For
        If IsIdentifierToken(candidate.name) = 0 OrElse _
           IsCDeclarationSpecifierKeyword(candidate.name) <> 0 Then Continue For
        declaration.declarator = candidate
        declaration.declaratorStartToken = candidateStart
        declaration.specifierEndToken = candidateStart - 1
        Return -1
    Next
    Return 0
End Function

Private Function SplitC2fbTokenList( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ranges() As C2fbTokenRangeModel, ByRef rangeCount As Long _
) As Long
    ' Commas inside function parameters, array bounds, and aggregate groups
    ' do not separate sibling declarators.
    rangeCount = 0
    If firstToken < 0 OrElse lastToken < firstToken OrElse _
       lastToken > UBound(tokens) Then Return 0
    ReDim ranges(0 To 7)

    Dim partStart As Long = firstToken
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    For tokenIndex As Long = firstToken To lastToken + 1
        Dim atEnd As Long = CInt(tokenIndex = lastToken + 1)
        If atEnd = 0 Then
            Select Case tokens(tokenIndex)
            Case "(": parenDepth += 1
            Case ")":
                If parenDepth = 0 Then Return 0
                parenDepth -= 1
            Case "[": bracketDepth += 1
            Case "]":
                If bracketDepth = 0 Then Return 0
                bracketDepth -= 1
            Case "{": braceDepth += 1
            Case "}":
                If braceDepth = 0 Then Return 0
                braceDepth -= 1
            End Select
        End If

        If (atEnd <> 0 OrElse tokens(tokenIndex) = ",") AndAlso _
           parenDepth = 0 AndAlso bracketDepth = 0 AndAlso braceDepth = 0 Then
            If partStart > tokenIndex - 1 OrElse rangeCount >= MAX_TYPE_WORDS Then Return 0
            If rangeCount > UBound(ranges) Then
                ReDim Preserve ranges(0 To UBound(ranges) * 2 + 1)
            End If
            ranges(rangeCount).firstToken = partStart
            ranges(rangeCount).lastToken = tokenIndex - 1
            rangeCount += 1
            partStart = tokenIndex + 1
        End If
    Next
    If parenDepth <> 0 OrElse bracketDepth <> 0 OrElse braceDepth <> 0 Then Return 0
    Return -1
End Function

Private Function FindC2fbTopLevelAssignmentToken( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef assignmentToken As Long _
) As Long
    assignmentToken = -1
    If firstToken < 0 OrElse lastToken < firstToken OrElse _
       lastToken > UBound(tokens) Then Return 0

    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        Select Case tokens(tokenIndex)
        Case "(": parenDepth += 1
        Case ")":
            If parenDepth = 0 Then Return 0
            parenDepth -= 1
        Case "[": bracketDepth += 1
        Case "]":
            If bracketDepth = 0 Then Return 0
            bracketDepth -= 1
        Case "{": braceDepth += 1
        Case "}":
            If braceDepth = 0 Then Return 0
            braceDepth -= 1
        Case "="
            If parenDepth = 0 AndAlso bracketDepth = 0 AndAlso _
               braceDepth = 0 Then
                assignmentToken = tokenIndex
                Return -1
            End If
        End Select
    Next
    If parenDepth <> 0 OrElse bracketDepth <> 0 OrElse braceDepth <> 0 Then Return 0
    Return -1
End Function

Private Function BuildC2fbDeclaratorPartTokens( _
    sourceTokens() As String, sourceRanges() As C2fbTokenRangeModel, _
    ByVal sourceRangeCount As Long, ByVal partIndex As Long, _
    ByVal commonTypeTokenCount As Long, itemTokens() As String, _
    ByRef itemTokenCount As Long _
) As Long
    ' Later comma-separated declarators omit the common C type in source.
    ' Restore the prefix from the first item before lowering each one.
    itemTokenCount = 0
    If sourceRangeCount <= 0 OrElse partIndex < 0 OrElse _
       partIndex >= sourceRangeCount Then Return 0

    Dim firstRange As C2fbTokenRangeModel = sourceRanges(0)
    Dim currentRange As C2fbTokenRangeModel = sourceRanges(partIndex)
    If firstRange.firstToken < 0 OrElse _
       firstRange.lastToken < firstRange.firstToken OrElse _
       firstRange.lastToken > UBound(sourceTokens) OrElse _
       currentRange.firstToken < 0 OrElse _
       currentRange.lastToken < currentRange.firstToken OrElse _
       currentRange.lastToken > UBound(sourceTokens) Then Return 0

    ReDim itemTokens(0 To 31)
    If partIndex = 0 Then
        For sourceTokenIndex As Long = _
            firstRange.firstToken To firstRange.lastToken
            If itemTokenCount >= MAX_C_DECLARATION_TOKENS Then Return 0
            AddToken(itemTokens(), itemTokenCount, sourceTokens(sourceTokenIndex))
        Next
        If itemTokenCount = 0 Then Return 0
        Return -1
    End If

    Dim firstRangeTokenCount As Long = _
        firstRange.lastToken - firstRange.firstToken + 1
    If commonTypeTokenCount <= 0 OrElse _
       commonTypeTokenCount > firstRangeTokenCount OrElse _
       commonTypeTokenCount > MAX_TYPE_WORDS OrElse _
       currentRange.lastToken - currentRange.firstToken + 1 > _
           MAX_C_DECLARATION_TOKENS - commonTypeTokenCount Then Return 0

    For sourceTokenIndex As Long = _
        firstRange.firstToken To _
        firstRange.firstToken + commonTypeTokenCount - 1
        AddToken(itemTokens(), itemTokenCount, sourceTokens(sourceTokenIndex))
    Next
    For sourceTokenIndex As Long = _
        currentRange.firstToken To currentRange.lastToken
        If itemTokenCount >= MAX_C_DECLARATION_TOKENS Then Return 0
        AddToken(itemTokens(), itemTokenCount, sourceTokens(sourceTokenIndex))
    Next
    Return -1
End Function

Private Sub AppendC2fbRecordFieldSource( _
    ByRef declaration As C2fbDeclarationModel, ByVal fieldText As String _
)
    fieldText = Trim(fieldText)
    If fieldText = "" Then Exit Sub
    If declaration.recordFieldCount >= _
       MAX_C2FB_DECLARATION_RECORD_FIELDS Then _
        ReportError("record exceeds the configured field declaration limit")
    If declaration.recordFieldCount > UBound(declaration.recordFields) Then _
        ReDim Preserve declaration.recordFields( _
            0 To UBound(declaration.recordFields) * 2 + 1)

    Dim fieldSource As C2fbRecordFieldSourceModel
    fieldSource.text = fieldText
    TokenizeCDeclaration(fieldText, fieldSource.tokens(), fieldSource.tokenCount)
    declaration.recordFields(declaration.recordFieldCount) = fieldSource
    declaration.recordFieldCount += 1
End Sub

Private Sub BuildC2fbRecordFieldSources(ByRef declaration As C2fbDeclarationModel)
    ReDim declaration.recordFields(0 To 7)
    declaration.recordFieldCount = 0
    declaration.recordFieldsComplete = 0
    ' Keep a valid empty body on the shared model path for body conversion.
    If Trim(declaration.recordBody) = "" Then
        declaration.recordFieldsComplete = -1
        Exit Sub
    End If

    Dim fieldStart As Long = 1
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    For position As Long = 1 To Len(declaration.recordBody)
        Dim currentByte As Long = Asc(declaration.recordBody, position)
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
            If parenDepth > 0 Then parenDepth -= 1
        ElseIf currentByte = Asc("[") Then
            bracketDepth += 1
        ElseIf currentByte = Asc("]") Then
            If bracketDepth > 0 Then bracketDepth -= 1
        ElseIf currentByte = Asc("{") Then
            braceDepth += 1
        ElseIf currentByte = Asc("}") Then
            If braceDepth > 0 Then braceDepth -= 1
        ElseIf currentByte = Asc(";") AndAlso parenDepth = 0 AndAlso _
               bracketDepth = 0 AndAlso braceDepth = 0 Then
            AppendC2fbRecordFieldSource( _
                declaration, Mid(declaration.recordBody, fieldStart, _
                position - fieldStart))
            fieldStart = position + 1
        End If
    Next

    If quoteByte <> 0 OrElse parenDepth <> 0 OrElse _
       bracketDepth <> 0 OrElse braceDepth <> 0 OrElse _
       Trim(Mid(declaration.recordBody, fieldStart)) <> "" OrElse _
       declaration.recordFieldCount = 0 Then Exit Sub
    declaration.recordFieldsComplete = -1
End Sub

Private Sub ResetC2fbDeclarationsInSourceUnit( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, ByVal initialCapacity As Long _
)
    If initialCapacity <= 0 OrElse initialCapacity > MAX_DECLARATIONS Then _
        ReportError("invalid initial declaration-table capacity")
    ReDim sourceUnit.declarations(0 To initialCapacity - 1)
    sourceUnit.declarationCount = 0
    sourceUnit.cppMode = 0
    sourceUnit.libraryPragmaCount = 0
End Sub

Private Sub AppendC2fbDeclarationInSourceUnit( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByRef declaration As C2fbDeclarationModel _
)
    Dim declarationEntry As C2fbDeclarationModel = declaration
    If declarationEntry.sourceSpan.startLocation.path = "" Then _
        declarationEntry.sourceSpan.startLocation.path = sourceUnit.diagnosticState.currentSourceLocation.path
    If (declarationEntry.entryKind = C2FB_DECLARATION_PLAIN OrElse _
        declarationEntry.entryKind = C2FB_DECLARATION_FUNCTION) AndAlso _
       Trim(declarationEntry.text) <> "" Then
        Dim normalizedDeclaration As String = declarationEntry.text
        Dim loweredDeclaration As String
        Dim linkName As String
        Dim hasAssemblyName As Long = ParseCAssemblyNameLabel( _
            normalizedDeclaration, loweredDeclaration, linkName)
        If hasAssemblyName <> 0 Then
            normalizedDeclaration = loweredDeclaration
            If hasAssemblyName < 0 Then
                declarationEntry.linkName = linkName
            Else
                declarationEntry.unsupportedAssemblyName = -1
            End If
        End If
        If declarationEntry.entryKind = C2FB_DECLARATION_PLAIN OrElse _
           hasAssemblyName <> 0 Then
            Dim wasFunction As Long = CInt( _
                declarationEntry.entryKind = C2FB_DECLARATION_FUNCTION)
            normalizedDeclaration = _
                StripCFunctionAttributes(normalizedDeclaration)
            Dim tokens() As String
            Dim tokenCount As Long
            TokenizeCDeclaration(normalizedDeclaration, tokens(), tokenCount)
            If tokenCount > 0 Then
                declarationEntry.tokenCount = tokenCount
                ReDim declarationEntry.tokens(0 To tokenCount - 1)
                For tokenIndex As Long = 0 To tokenCount - 1
                    declarationEntry.tokens(tokenIndex) = tokens(tokenIndex)
                Next
                Dim functionDeclaration As C2fbFunctionDeclarationModel
                If ParseCFunctionDeclarationModel( _
                    declarationEntry.tokens(), tokenCount, functionDeclaration, _
                    sourceUnit.cppMode) <> 0 Then
                    declarationEntry.entryKind = C2FB_DECLARATION_FUNCTION
                    declarationEntry.sourceName = functionDeclaration.declarator.name
                    declarationEntry.functionDeclaration = functionDeclaration
                Else
                    declarationEntry.entryKind = C2FB_DECLARATION_PLAIN
                    If wasFunction <> 0 Then declarationEntry.sourceName = ""
                End If
            End If
        End If
    ElseIf declarationEntry.entryKind = C2FB_DECLARATION_RECORD Then
        BuildC2fbRecordFieldSources(declarationEntry)
    End If
    If sourceUnit.declarationCount >= MAX_DECLARATIONS Then _
        ReportError("translation unit exceeds the configured declaration limit")
    If sourceUnit.declarationCount > UBound(sourceUnit.declarations) Then _
        ReDim Preserve sourceUnit.declarations(0 To UBound(sourceUnit.declarations) * 2 + 1)
    sourceUnit.declarations(sourceUnit.declarationCount) = declarationEntry
    sourceUnit.declarationCount += 1
End Sub

/' end of c2fb_declarations.bi '/
