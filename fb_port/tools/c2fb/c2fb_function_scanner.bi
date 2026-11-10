/'
    Project: C2FB shared C front end

    File: c2fb_function_scanner.bi

    Purpose:

        Collect C declarations, records, prototypes, and function definitions
        through one source-aware translation-unit scanner.

    Responsibilities:

        - Track source lines, preprocessor markers, comments, quotes, braces,
          and packing.
        - Emit ordinary declarations, records, prototypes, and definitions
          through one model.
        - Parse prototypes and definitions with the shared declarator model.
        - Apply a typed request that carries source identity and scan policy.
        - Derive internal scanner settings from the request's named profile.
        - Provide named request builders for translation, prototype, body, and inventory scans.
        - Keep record bodies and pack state in the same source scan.
        - Hoist tagged nested aggregate definitions before enclosing records.
        - Preserve aggregate initializers that follow inline record definitions.
        - Retain source locations on collected library pragmas.
        - Add block-local record declarations discovered in streamed bodies.
        - Offer an inventory mode that resets branch state and skips unused bodies/records.
        - Collect selected scanner results into the translation-unit model.
        - Preserve source location and header-body metadata for later lowering.
        - Bound memory use by retaining only the current body when requested.

    This file intentionally does NOT contain:

        - C statement lowering, target type mapping, or FreeBASIC output.
        - Preprocessor evaluation; the configured C compiler owns that step.
'/

Private Const MAX_C2FB_FUNCTION_CONDITIONAL_DEPTH As Long = 256
Private Const MAX_C2FB_NESTED_TAG_DEPTH As Long = 16
Private Declare Function IsIncludedPreprocessedCSource( _
    ByVal sourcePath As String _
) As Long

Private Type C2fbFunctionScannerBranchStateModel
    declaration As String
    declarationStartLocation As C2fbSourceLocationModel
    declarationOriginCaptured As Long
    braceDepth As Long
    insideFunction As Long
    insideCLinkage As Long
    skipDeclarationTail As Long
    body As String
End Type

/' ------------------------------------------------------------------------- '/
/' C record prefix recognition and packing directives                    '/
/' ------------------------------------------------------------------------- '/

Private Function C2fbRecordKindFromPrefix( _
    ByVal prefix As String, ByRef recordTag As String, _
    ByRef isTypedef As Long, ByRef isPacked As Long _
) As C2fbRecordKind
    recordTag = ""
    isTypedef = 0
    isPacked = 0

    Dim rawTokens() As String
    Dim rawCount As Long
    TokenizeCDeclaration(prefix, rawTokens(), rawCount)
    For tokenIndex As Long = 0 To rawCount - 1
        Select Case LCase(rawTokens(tokenIndex))
        Case "packed", "__packed__": isPacked = -1
        End Select
    Next

    Dim normalized As String = StripCFunctionAttributes(prefix)
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(normalized, tokens(), tokenCount)
    If tokenCount = 0 Then Return C2FB_RECORD_KIND_NONE
    For tokenIndex As Long = 0 To tokenCount - 1
        If tokens(tokenIndex) = "(" OrElse tokens(tokenIndex) = ")" OrElse _
           tokens(tokenIndex) = "=" Then Return C2FB_RECORD_KIND_NONE
    Next

    Dim typePosition As Long = 0
    If tokens(typePosition) = "typedef" Then
        isTypedef = -1
        typePosition += 1
    End If
    While typePosition < tokenCount
        Select Case tokens(typePosition)
        Case "auto", "register", "static", "extern", "inline", _
             "const", "volatile", "restrict", "__restrict", "__restrict__", _
             "SQLITE_API", "SQLITE_PRIVATE"
            typePosition += 1
        Case Else
            Exit While
        End Select
    Wend
    If typePosition >= tokenCount Then Return C2FB_RECORD_KIND_NONE

    Select Case tokens(typePosition)
    Case "struct": C2fbRecordKindFromPrefix = C2FB_RECORD_STRUCT
    Case "union": C2fbRecordKindFromPrefix = C2FB_RECORD_UNION
    Case "enum": C2fbRecordKindFromPrefix = C2FB_RECORD_ENUM
    Case Else: Return C2FB_RECORD_KIND_NONE
    End Select
    If typePosition + 1 < tokenCount AndAlso _
       IsIdentifierToken(tokens(typePosition + 1)) <> 0 Then
        recordTag = tokens(typePosition + 1)
    End If
End Function

Private Function C2fbAnonymousRecordAlias( _
    ByVal recordKind As C2fbRecordKind, ByVal inputOrder As LongInt _
) As String
    Dim kindName As String = "record"
    Select Case recordKind
    Case C2FB_RECORD_UNION: kindName = "union"
    Case C2FB_RECORD_ENUM: kindName = "enum"
    End Select
    Return "__c2fb_anonymous_" & kindName & "_" & Trim(Str(inputOrder))
End Function

Private Function ParseC2fbAlignmentAttributes( _
    ByVal sourceText As String, ByRef recordAlignment As Long _
) As Long
    recordAlignment = 0
    Dim searchPosition As Long = 1
    While searchPosition <= Len(sourceText)
        Dim attributePosition As Long = InStr( _
            searchPosition, sourceText, "__attribute__")
        If attributePosition = 0 Then Exit While
        Dim openingGroup As Long = attributePosition + Len("__attribute__")
        While openingGroup <= Len(sourceText) AndAlso _
              IsSpaceByte(Asc(sourceText, openingGroup)) <> 0
            openingGroup += 1
        Wend
        If openingGroup > Len(sourceText) OrElse _
           Asc(sourceText, openingGroup) <> Asc("(") Then Return 0
        Dim closingGroup As Long = openingGroup
        If ScanSimpleExpressionGroup( _
            sourceText, closingGroup, Asc("("), Asc(")")) = 0 Then Return 0

        Dim alignedPosition As Long = openingGroup
        While alignedPosition < closingGroup
            alignedPosition = InStr(alignedPosition, sourceText, "aligned")
            If alignedPosition = 0 OrElse alignedPosition >= closingGroup Then Exit While
            Dim beforeIsIdentifier As Long = 0
            Dim afterIsIdentifier As Long = 0
            If alignedPosition > 1 Then _
                beforeIsIdentifier = IsIdentifierPart(Asc(sourceText, alignedPosition - 1))
            If alignedPosition + Len("aligned") <= Len(sourceText) Then _
                afterIsIdentifier = IsIdentifierPart( _
                    Asc(sourceText, alignedPosition + Len("aligned")))
            If beforeIsIdentifier = 0 AndAlso afterIsIdentifier = 0 Then
                Dim openingAlignment As Long = alignedPosition + Len("aligned")
                While openingAlignment <= closingGroup AndAlso _
                      IsSpaceByte(Asc(sourceText, openingAlignment)) <> 0
                    openingAlignment += 1
                Wend
                If openingAlignment > closingGroup OrElse _
                   Asc(sourceText, openingAlignment) <> Asc("(") Then Return 0
                Dim closingAlignment As Long = openingAlignment
                If ScanSimpleExpressionGroup( _
                    sourceText, closingAlignment, Asc("("), Asc(")")) = 0 OrElse _
                   closingAlignment > closingGroup Then Return 0
                Dim alignmentExpression As String = Trim(Mid( _
                    sourceText, openingAlignment + 1, _
                    closingAlignment - openingAlignment - 2))
                Dim requestedAlignment As Long
                If EvaluateSimpleArrayBound( _
                    alignmentExpression, requestedAlignment, _
                    MAX_GENERIC_ARRAY_COUNT) = 0 Then Return 0
                Select Case requestedAlignment
                Case 1, 2, 4, 8
                    If requestedAlignment > recordAlignment Then _
                        recordAlignment = requestedAlignment
                Case Else
                    ' FBC can raise alignment by overlaying a matching scalar.
                    Return 0
                End Select
                alignedPosition = closingAlignment
            Else
                alignedPosition += Len("aligned")
            End If
        Wend
        searchPosition = closingGroup
    Wend
    Return -1
End Function

Private Function C2fbRecordHasUnsupportedAlignment( _
    ByVal prefix As String, ByVal tail As String, _
    ByRef recordAlignment As Long, ByRef tailAlignment As Long _
) As Long
    tailAlignment = 0
    Dim allAttributes As String = LCase(prefix & " " & tail)
    If InStr(allAttributes, "ms_struct") <> 0 OrElse _
       InStr(allAttributes, "scalar_storage_order") <> 0 OrElse _
       (InStr(allAttributes, "__declspec") <> 0 AndAlso _
        InStr(allAttributes, "align") <> 0) Then Return -1

    If ParseC2fbAlignmentAttributes(prefix, recordAlignment) = 0 Then Return -1
    If ParseC2fbAlignmentAttributes(tail, tailAlignment) = 0 Then Return -1
    Return 0
End Function

Private Function SplitNestedTaggedRecordField( _
    ByVal fieldText As String, ByRef recordPrefix As String, _
    ByRef recordBody As String, ByRef recordTail As String, _
    ByRef recordTag As String, ByRef recordKind As C2fbRecordKind, _
    ByRef recordPacked As Long _
) As Long
    recordPrefix = ""
    recordBody = ""
    recordTail = ""
    recordTag = ""
    recordKind = C2FB_RECORD_KIND_NONE
    recordPacked = 0

    Dim openingBrace As Long = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    For position As Long = 1 To Len(fieldText)
        Dim currentByte As Long = Asc(fieldText, position)
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
            If parenDepth = 0 Then Return 0
            parenDepth -= 1
        ElseIf currentByte = Asc("[") Then
            bracketDepth += 1
        ElseIf currentByte = Asc("]") Then
            If bracketDepth = 0 Then Return 0
            bracketDepth -= 1
        ElseIf currentByte = Asc("{") AndAlso _
               parenDepth = 0 AndAlso bracketDepth = 0 Then
            openingBrace = position
            Exit For
        End If
    Next
    If openingBrace = 0 OrElse quoteByte <> 0 OrElse _
       parenDepth <> 0 OrElse bracketDepth <> 0 Then Return 0

    recordPrefix = Trim(Left(fieldText, openingBrace - 1))
    Dim isTypedef As Long
    recordKind = C2fbRecordKindFromPrefix( _
        recordPrefix, recordTag, isTypedef, recordPacked)
    If (recordKind <> C2FB_RECORD_STRUCT AndAlso _
        recordKind <> C2FB_RECORD_UNION AndAlso _
        recordKind <> C2FB_RECORD_ENUM) OrElse _
       (recordKind = C2FB_RECORD_ENUM AndAlso recordTag = "") OrElse _
       isTypedef <> 0 Then Return 0

    Dim closingPosition As Long = openingBrace
    If ScanSimpleExpressionGroup( _
        fieldText, closingPosition, Asc("{"), Asc("}")) = 0 Then Return 0
    recordBody = Mid( _
        fieldText, openingBrace + 1, closingPosition - openingBrace - 2)
    recordTail = Trim(Mid(fieldText, closingPosition))
    Return -1
End Function

Private Function NormalizeNestedTaggedRecordBody( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByRef declaration As C2fbDeclarationModel, ByVal nestingDepth As Long _
) As Long
    If nestingDepth > MAX_C2FB_NESTED_TAG_DEPTH Then Return 0
    If declaration.recordKind = C2FB_RECORD_ENUM Then Return -1
    BuildC2fbRecordFieldSources(declaration)
    If declaration.recordFieldsComplete = 0 Then Return 0

    Dim normalizedBody As String
    For fieldIndex As Long = 0 To declaration.recordFieldCount - 1
        Dim fieldText As String = declaration.recordFields(fieldIndex).text
        Dim normalizedFieldText As String
        For textPosition As Long = 1 To Len(fieldText)
            Dim fieldByte As Long = Asc(fieldText, textPosition)
            If fieldByte = 10 OrElse fieldByte = 13 Then
                normalizedFieldText &= " "
            Else
                normalizedFieldText &= Chr(fieldByte)
            End If
        Next
        fieldText = normalizedFieldText
        Dim nestedPrefix As String
        Dim nestedBody As String
        Dim nestedTail As String
        Dim nestedTag As String
        Dim nestedKind As C2fbRecordKind
        Dim nestedPacked As Long
        If SplitNestedTaggedRecordField( _
            fieldText, nestedPrefix, nestedBody, nestedTail, nestedTag, _
            nestedKind, nestedPacked) <> 0 Then
            If nestingDepth >= MAX_C2FB_NESTED_TAG_DEPTH Then Return 0
            If nestedTag <> "" Then
                If nestedTag = declaration.recordTag Then Return 0
                Dim nestedDeclaration As C2fbDeclarationModel
                nestedDeclaration.entryKind = C2FB_DECLARATION_RECORD
                nestedDeclaration.text = nestedPrefix
                nestedDeclaration.recordPrefix = nestedPrefix
                nestedDeclaration.recordBody = nestedBody
                nestedDeclaration.recordTag = nestedTag
                nestedDeclaration.recordKind = nestedKind
                nestedDeclaration.isPacked = nestedPacked
                nestedDeclaration.packValue = declaration.packValue
                Dim nestedTailAlignment As Long
                If C2fbRecordHasUnsupportedAlignment( _
                    nestedPrefix, nestedTail, nestedDeclaration.recordAlignment, _
                    nestedTailAlignment) <> 0 OrElse nestedTailAlignment <> 0 Then _
                    nestedDeclaration.unsupported = -1
                If nestedDeclaration.recordAlignment > 0 AndAlso _
                   (nestedDeclaration.isPacked <> 0 OrElse _
                    nestedDeclaration.packValue > 0) Then _
                    nestedDeclaration.unsupported = -1
                nestedDeclaration.sourceSpan = declaration.sourceSpan
                nestedDeclaration.hasNestedRecord = _
                    CInt(InStr(nestedBody, "{") <> 0) * -1

                If nestedKind <> C2FB_RECORD_ENUM AndAlso _
                   NormalizeNestedTaggedRecordBody( _
                       sourceUnit, nestedDeclaration, nestingDepth + 1) = 0 Then _
                    nestedDeclaration.unsupported = -1
                AppendC2fbDeclarationInSourceUnit( _
                    sourceUnit, nestedDeclaration)

                If nestedTail <> "" Then _
                    normalizedBody &= nestedPrefix & " " & nestedTail & "; "
            Else
                Dim anonymousDeclaration As C2fbDeclarationModel
                anonymousDeclaration.recordKind = nestedKind
                anonymousDeclaration.recordBody = nestedBody
                anonymousDeclaration.recordPrefix = nestedPrefix
                anonymousDeclaration.packValue = declaration.packValue
                anonymousDeclaration.isPacked = nestedPacked
                anonymousDeclaration.sourceSpan = declaration.sourceSpan
                If NormalizeNestedTaggedRecordBody( _
                    sourceUnit, anonymousDeclaration, nestingDepth + 1) = 0 Then _
                    Return 0
                If Trim(anonymousDeclaration.recordBody) = "" AndAlso _
                   Trim(nestedTail) = "" Then Continue For
                normalizedBody &= nestedPrefix & " {" & _
                    anonymousDeclaration.recordBody & "}"
                If nestedTail <> "" Then normalizedBody &= " " & nestedTail
                normalizedBody &= "; "
            End If
        Else
            normalizedBody &= fieldText & "; "
        End If
    Next
    declaration.recordBody = normalizedBody
    Return -1
End Function

Private Function C2fbPackNumber(ByVal packText As String) As Long
    For position As Long = 1 To Len(packText)
        If Asc(packText, position) >= Asc("0") AndAlso _
           Asc(packText, position) <= Asc("9") Then
            Dim finish As Long = position + 1
            While finish <= Len(packText) AndAlso _
                  Asc(packText, finish) >= Asc("0") AndAlso _
                  Asc(packText, finish) <= Asc("9")
                finish += 1
            Wend
            Return Val(Mid(packText, position, finish - position))
        End If
    Next
    Return -1
End Function

Private Function UpdateC2fbPackState( _
    ByVal lineText As String, ByRef packValue As Long, _
    packStack() As Long, ByRef packDepth As Long _
) As Long
    Dim lowered As String = LCase(Trim(lineText))
    If Left(lowered, 7) <> "#pragma" OrElse InStr(lowered, "pack") = 0 Then Return 0
    Dim openParen As Long = InStr(lowered, "(")
    If openParen = 0 Then
        packValue = -1
        Return -1
    End If
    Dim closeParen As Long = InStr(openParen + 1, lowered, ")")
    If closeParen = 0 Then
        packValue = -1
        Return -1
    End If
    Dim arguments As String = Trim(Mid(lowered, openParen + 1, closeParen - openParen - 1))
    Dim pushed As Long = CInt(Left(arguments, 4) = "push")
    Dim popped As Long = CInt(Left(arguments, 3) = "pop")
    If pushed <> 0 Then
        If packDepth >= UBound(packStack) + 1 Then
            packValue = -1
            Return -1
        End If
        packStack(packDepth) = packValue
        packDepth += 1
        arguments = Trim(Mid(arguments, 5))
        If Left(arguments, 1) = "," Then arguments = Trim(Mid(arguments, 2))
    ElseIf popped <> 0 Then
        If packDepth > 0 Then
            packDepth -= 1
            packValue = packStack(packDepth)
        Else
            packValue = 0
        End If
        arguments = Trim(Mid(arguments, 4))
        If Left(arguments, 1) = "," Then arguments = Trim(Mid(arguments, 2))
    End If
    If InStr(arguments, "show") <> 0 Then Return -1
    If arguments = "" Then
        If pushed = 0 AndAlso popped = 0 Then packValue = 0
        Return -1
    End If
    Dim requestedPack As Long = C2fbPackNumber(arguments)
    If requestedPack < 0 Then
        packValue = -1
    Else
        packValue = requestedPack
    End If
    Return -1
End Function

Private Type C2fbFunctionScanner
    physicalLineReader As C2fbPhysicalSourceLineReaderModel
    isFinished As Long
    options As C2fbFunctionScannerSettingsModel
    insideCLinkage As Long
    rootSourcePath As String
    declarationStartLocation As C2fbSourceLocationModel
    declarationInputOrder As LongInt
    declarationOriginCaptured As Long
    lineText As String
    linePosition As Long
    braceDepth As Long
    declarationParenDepth As Long
    declarationBracketDepth As Long
    declarationBraceDepth As Long
    insideFunction As Long
    skipDeclarationTail As Long
    recordOpen As Long
    recordClosed As Long
    recordKind As C2fbRecordKind
    recordTypedef As Long
    recordPacked As Long
    recordPackValue As Long
    recordNested As Long
    recordSourceLocation As C2fbSourceLocationModel
    recordInputOrder As LongInt
    recordPrefix As String
    recordBody As String
    recordTail As String
    recordTag As String
    packValue As Long
    packDepth As Long
    packStack(0 To 31) As Long
    currentSourcePath As String
    declaration As String
    body As String
    conditionalDepth As Long
    conditionalBranches(0 To MAX_C2FB_FUNCTION_CONDITIONAL_DEPTH - 1) As C2fbFunctionScannerBranchStateModel
    skipDirectiveContinuation As Long
    quote As Long
    escaped As Long
    currentSourceIsRoot As Long
End Type

Private Sub UpdateC2fbDeclarationGroupDepth( _
    ByRef scanner As C2fbFunctionScanner, ByVal currentByte As Long _
)
    Select Case currentByte
    Case Asc("(")
        scanner.declarationParenDepth += 1
    Case Asc(")")
        If scanner.declarationParenDepth > 0 Then _
            scanner.declarationParenDepth -= 1
    Case Asc("[")
        scanner.declarationBracketDepth += 1
    Case Asc("]")
        If scanner.declarationBracketDepth > 0 Then _
            scanner.declarationBracketDepth -= 1
    End Select
End Sub

Private Sub InitializeC2fbDeclarationScanRequest( _
    ByRef request As C2fbDeclarationScanRequestModel, _
    ByVal inputPath As String, ByVal rootSourcePath As String _
)
    request.inputPath = inputPath
    request.rootSourcePath = rootSourcePath
    request.profile = C2FB_FUNCTION_SCAN_INVALID
    request.options.sourceMapMode = C2FB_SOURCE_MAP_DISABLED
    request.options.sourceOriginPrecision = C2FB_SOURCE_ORIGIN_LINES_AVAILABLE
    request.options.collectLibraryPragmas = C2FB_LIBRARY_PRAGMAS_IGNORE
    request.options.collectHeaderInlineBodies = 0
    request.options.includeHeaderBodyNames = ""
    request.options.collectIncludedCSourceBodies = 0
End Sub

Private Sub ConfigureC2fbTranslationUnitScanRequest( _
    ByRef request As C2fbDeclarationScanRequestModel, _
    ByVal inputPath As String, ByVal rootSourcePath As String _
)
    InitializeC2fbDeclarationScanRequest(request, inputPath, rootSourcePath)
    request.profile = C2FB_FUNCTION_SCAN_TRANSLATION_UNIT
End Sub

Private Sub ConfigureC2fbPrototypeScanRequest( _
    ByRef request As C2fbDeclarationScanRequestModel, _
    ByVal inputPath As String, ByVal rootSourcePath As String _
)
    InitializeC2fbDeclarationScanRequest(request, inputPath, rootSourcePath)
    request.profile = C2FB_FUNCTION_SCAN_PROTOTYPES_ONLY
End Sub

Private Sub ConfigureC2fbBodyDeclarationScanRequest( _
    ByRef request As C2fbDeclarationScanRequestModel, _
    ByVal inputPath As String, ByVal rootSourcePath As String _
)
    InitializeC2fbDeclarationScanRequest(request, inputPath, rootSourcePath)
    request.profile = C2FB_FUNCTION_SCAN_BODY_DECLARATIONS
End Sub

Private Sub ConfigureC2fbFunctionBodyScanRequest( _
    ByRef request As C2fbDeclarationScanRequestModel, _
    ByVal inputPath As String, ByVal rootSourcePath As String _
)
    InitializeC2fbDeclarationScanRequest(request, inputPath, rootSourcePath)
    request.profile = C2FB_FUNCTION_SCAN_BODY_STREAM
End Sub

Private Sub ConfigureC2fbFunctionInventoryScanRequest( _
    ByRef request As C2fbDeclarationScanRequestModel, _
    ByVal inputPath As String, ByVal rootSourcePath As String _
)
    InitializeC2fbDeclarationScanRequest(request, inputPath, rootSourcePath)
    request.profile = C2FB_FUNCTION_SCAN_INVENTORY
End Sub

Private Function ConfigureC2fbFunctionScannerSettings( _
    ByRef request As C2fbDeclarationScanRequestModel, _
    ByRef settings As C2fbFunctionScannerSettingsModel _
) As Long
    settings.sourceMapMode = request.options.sourceMapMode
    settings.sourceOriginPrecision = request.options.sourceOriginPrecision
    settings.collectLibraryPragmas = request.options.collectLibraryPragmas
    settings.collectFunctionDefinitions = 0
    settings.collectRecordModels = 0
    settings.retainFunctionBodies = 0
    settings.collectHeaderInlineBodies = _
        request.options.collectHeaderInlineBodies
    settings.includeHeaderBodyNames = _
        request.options.includeHeaderBodyNames
    settings.collectIncludedCSourceBodies = _
        request.options.collectIncludedCSourceBodies
    settings.recognizeCLinkageBlocks = 0
    settings.resetConditionalBranches = 0

    Select Case request.profile
    Case C2FB_FUNCTION_SCAN_TRANSLATION_UNIT, _
         C2FB_FUNCTION_SCAN_PROTOTYPES_ONLY
        settings.collectRecordModels = -1
        settings.retainFunctionBodies = -1
        settings.recognizeCLinkageBlocks = -1
    Case C2FB_FUNCTION_SCAN_BODY_DECLARATIONS
        settings.collectFunctionDefinitions = -1
        settings.collectRecordModels = -1
        settings.retainFunctionBodies = -1
        settings.recognizeCLinkageBlocks = -1
    Case C2FB_FUNCTION_SCAN_BODY_STREAM
        settings.collectFunctionDefinitions = -1
        settings.retainFunctionBodies = -1
        settings.recognizeCLinkageBlocks = -1
    Case C2FB_FUNCTION_SCAN_INVENTORY
        settings.collectFunctionDefinitions = -1
        settings.resetConditionalBranches = -1
    Case Else
        Return 0
    End Select
    Return -1
End Function

Private Function OpenC2fbFunctionScanner( _
    ByRef scanner As C2fbFunctionScanner, _
    ByRef request As C2fbDeclarationScanRequestModel _
) As Long
    Dim scannerSettings As C2fbFunctionScannerSettingsModel
    If ConfigureC2fbFunctionScannerSettings(request, scannerSettings) = 0 Then Return 0
    If OpenC2fbPhysicalSourceLineReader( _
        scanner.physicalLineReader, request.inputPath) = 0 Then Return 0
    scanner.isFinished = 0
    scanner.options = scannerSettings
    scanner.insideCLinkage = 0
    scanner.rootSourcePath = request.rootSourcePath
    scanner.currentSourcePath = request.inputPath
    scanner.declarationStartLocation.line = 0
    scanner.declarationStartLocation.path = ""
    scanner.declarationStartLocation.column = 0
    scanner.declarationInputOrder = 0
    scanner.declarationOriginCaptured = 0
    scanner.linePosition = 0
    scanner.braceDepth = 0
    scanner.declarationParenDepth = 0
    scanner.declarationBracketDepth = 0
    scanner.declarationBraceDepth = 0
    scanner.insideFunction = 0
    scanner.skipDeclarationTail = 0
    scanner.recordOpen = 0
    scanner.recordClosed = 0
    scanner.recordKind = C2FB_RECORD_KIND_NONE
    scanner.recordTypedef = 0
    scanner.recordPacked = 0
    scanner.recordPackValue = 0
    scanner.recordNested = 0
    scanner.recordSourceLocation.line = 0
    scanner.recordSourceLocation.path = ""
    scanner.recordSourceLocation.column = 0
    scanner.recordInputOrder = 0
    scanner.recordPrefix = ""
    scanner.recordBody = ""
    scanner.recordTail = ""
    scanner.recordTag = ""
    scanner.packValue = 0
    scanner.packDepth = 0
    For packIndex As Long = 0 To UBound(scanner.packStack)
        scanner.packStack(packIndex) = 0
    Next
    scanner.declaration = ""
    scanner.body = ""
    scanner.conditionalDepth = 0
    scanner.skipDirectiveContinuation = 0
    scanner.quote = 0
    scanner.escaped = 0
    scanner.currentSourceIsRoot = -1
    Return -1
End Function

Private Sub CloseC2fbFunctionScanner(ByRef scanner As C2fbFunctionScanner)
    CloseC2fbPhysicalSourceLineReader(scanner.physicalLineReader)
    scanner.isFinished = -1
End Sub

Private Function C2fbScannerHasSourceLineLocations( _
    ByRef scanner As C2fbFunctionScanner _
) As Long
    Return CInt( _
        scanner.options.sourceOriginPrecision = _
        C2FB_SOURCE_ORIGIN_LINES_AVAILABLE)
End Function

Private Function C2fbScannedDeclarationIsNoReturn( _
    ByVal declarationText As String _
) As Long
    Dim loweredDeclaration As String = LCase(declarationText)
    Dim attributePosition As Long = InStr(loweredDeclaration, "__attribute")
    If attributePosition > 0 AndAlso _
       InStr(attributePosition, loweredDeclaration, "noreturn") > 0 Then _
        Return -1
    Dim declspecPosition As Long = InStr(loweredDeclaration, "__declspec")
    If declspecPosition > 0 AndAlso _
       InStr(declspecPosition, loweredDeclaration, "noreturn") > 0 Then _
        Return -1

    Dim tokens() As String
    Dim tokenCount As Long = 0
    TokenizeCDeclaration(declarationText, tokens(), tokenCount)
    For tokenIndex As Long = 0 To tokenCount - 1
        Dim loweredToken As String = LCase(tokens(tokenIndex))
        Select Case loweredToken
        Case "_noreturn", "__noreturn", "__noreturn__"
            Return -1
        End Select

        If loweredToken = "__attribute__" OrElse _
           loweredToken = "__attribute" OrElse loweredToken = "__declspec" Then
            Dim openPosition As Long = tokenIndex + 1
            If openPosition > tokenCount - 1 OrElse _
               tokens(openPosition) <> "(" Then Continue For
            Dim depth As Long = 0
            For attributeToken As Long = openPosition To tokenCount - 1
                Select Case tokens(attributeToken)
                Case "(": depth += 1
                Case ")":
                    depth -= 1
                    If depth = 0 Then Exit For
                Case Else
                    Select Case LCase(tokens(attributeToken))
                    Case "noreturn", "_noreturn", "__noreturn", "__noreturn__"
                        Return -1
                    End Select
                End Select
            Next
        ElseIf tokens(tokenIndex) = "[" AndAlso _
               tokenIndex < tokenCount - 1 AndAlso _
               tokens(tokenIndex + 1) = "[" Then
            For attributeToken As Long = tokenIndex + 2 To tokenCount - 1
                If tokens(attributeToken) = "]" AndAlso _
                   attributeToken < tokenCount - 1 AndAlso _
                   tokens(attributeToken + 1) = "]" Then Exit For
                Select Case LCase(tokens(attributeToken))
                Case "noreturn", "_noreturn", "__noreturn", "__noreturn__"
                    Return -1
                End Select
            Next
        End If
    Next
    Return 0
End Function

Private Function ParseScannedCFunctionDeclaration( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByRef scanner As C2fbFunctionScanner, _
    ByRef sourceItem As C2fbSourceItemModel, _
    ByVal sourceText As String, ByVal isDefinition As Long _
) As Long
    Dim loweredDeclaration As String = sourceText
    Dim linkName As String
    Dim assemblyNameStatus As Long = ParseCAssemblyNameLabel( _
        sourceText, loweredDeclaration, linkName)
    If assemblyNameStatus > 0 Then Return 0
    Dim normalizedDeclaration As String = _
        StripCFunctionAttributes(loweredDeclaration)
    Dim declarationTokens() As String
    Dim declarationTokenCount As Long = 0
    TokenizeCDeclaration( _
        normalizedDeclaration, declarationTokens(), declarationTokenCount)
    Dim functionDeclaration As C2fbFunctionDeclarationModel
    If ParseCFunctionDeclarationModel( _
        declarationTokens(), declarationTokenCount, functionDeclaration) = 0 Then _
        Return 0

    sourceItem.declaration.sourceName = _
        functionDeclaration.declarator.name
    sourceItem.declaration.linkName = linkName
    sourceItem.declaration.inputOrder = scanner.declarationInputOrder
    sourceItem.declaration.text = normalizedDeclaration
    sourceItem.declaration.functionDeclaration = functionDeclaration
    sourceItem.declaration.entryKind = C2FB_DECLARATION_FUNCTION
    sourceItem.declaration.isFunctionDefinition = isDefinition
    sourceItem.declaration.isNoReturn = _
        C2fbScannedDeclarationIsNoReturn(sourceText)
    sourceItem.declaration.isConditional = _
        CInt(scanner.conditionalDepth <> 0)
    sourceItem.declaration.tokenCount = declarationTokenCount
    ReDim sourceItem.declaration.tokens(0 To declarationTokenCount - 1)
    For tokenIndex As Long = 0 To declarationTokenCount - 1
        sourceItem.declaration.tokens(tokenIndex) = declarationTokens(tokenIndex)
    Next
    sourceItem.declaration.sourceSpan.startLocation = scanner.declarationStartLocation
    If sourceItem.declaration.sourceSpan.startLocation.path = "" Then _
        sourceItem.declaration.sourceSpan.startLocation.path = sourceUnit.diagnosticState.currentSourceLocation.path
    sourceItem.declaration.sourceSpan.startLocation.line = scanner.declarationStartLocation.line
    If C2fbScannerHasSourceLineLocations(scanner) <> 0 AndAlso _
       sourceItem.declaration.sourceSpan.startLocation.line = 0 Then _
        sourceItem.declaration.sourceSpan.startLocation.line = scanner.physicalLineReader.lineNumber
    sourceItem.declaration.sourceSpan.endLocation.path = ""
    sourceItem.declaration.sourceSpan.endLocation.line = 0
    sourceItem.declaration.sourceSpan.endLocation.column = 0
    If C2fbScannerHasSourceLineLocations(scanner) = 0 Then
        sourceItem.declaration.sourceSpan.startLocation.column = 0
    ElseIf scanner.options.sourceMapMode <> C2FB_SOURCE_MAP_DISABLED Then
        ' Line markers retain logical lines, but macro expansion can change columns.
        sourceItem.declaration.sourceSpan.startLocation.column = 0
    End If
    If isDefinition = 0 Then
        sourceItem.declaration.sourceSpan.endLocation = _
            sourceUnit.diagnosticState.currentSourceLocation
        If C2fbScannerHasSourceLineLocations(scanner) <> 0 Then _
            sourceItem.declaration.sourceSpan.endLocation.line = _
                scanner.physicalLineReader.lineNumber
    End If
    sourceItem.declaration.hasDirectives = _
        CInt(scanner.conditionalDepth <> 0)
    sourceItem.declaration.isHeaderBody = CInt( _
        isDefinition <> 0 AndAlso _
        scanner.options.sourceMapMode <> C2FB_SOURCE_MAP_DISABLED AndAlso _
        scanner.currentSourceIsRoot = 0 AndAlso _
        Not (scanner.options.collectIncludedCSourceBodies <> 0 AndAlso _
             IsIncludedPreprocessedCSource(scanner.currentSourcePath) <> 0))
    sourceItem.body = ""
    Return -1
End Function

Private Sub ResetC2fbScannedRecordState(ByRef scanner As C2fbFunctionScanner)
    scanner.recordOpen = 0
    scanner.recordClosed = 0
    scanner.recordKind = C2FB_RECORD_KIND_NONE
    scanner.recordTypedef = 0
    scanner.recordPacked = 0
    scanner.recordPackValue = 0
    scanner.recordNested = 0
    scanner.recordSourceLocation.line = 0
    scanner.recordSourceLocation.path = ""
    scanner.recordSourceLocation.column = 0
    scanner.recordInputOrder = 0
    scanner.recordPrefix = ""
    scanner.recordBody = ""
    scanner.recordTail = ""
    scanner.recordTag = ""
End Sub

Private Sub SetC2fbScannedRecordModel( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByRef scanner As C2fbFunctionScanner, _
    ByRef sourceItem As C2fbSourceItemModel _
)
    Dim entry As C2fbDeclarationModel
    entry.entryKind = C2FB_DECLARATION_RECORD
    entry.text = Trim(scanner.recordPrefix)
    entry.recordPrefix = Trim(scanner.recordPrefix)
    entry.recordBody = scanner.recordBody
    entry.recordTail = Trim(scanner.recordTail)
    entry.recordTag = scanner.recordTag
    entry.sourceSpan.startLocation = scanner.recordSourceLocation
    entry.inputOrder = scanner.recordInputOrder
    entry.sourceSpan.endLocation = sourceUnit.diagnosticState.currentSourceLocation
    If C2fbScannerHasSourceLineLocations(scanner) <> 0 Then _
        entry.sourceSpan.endLocation.line = scanner.physicalLineReader.lineNumber
    entry.recordKind = scanner.recordKind
    entry.isTypedef = scanner.recordTypedef
    entry.isPacked = scanner.recordPacked
    entry.packValue = scanner.recordPackValue
    entry.hasNestedRecord = scanner.recordNested

    Dim tailAttributeTokens() As String
    Dim tailAttributeCount As Long
    TokenizeCDeclaration( _
        entry.recordTail, tailAttributeTokens(), tailAttributeCount)
    For tailIndex As Long = 0 To tailAttributeCount - 1
        Select Case LCase(tailAttributeTokens(tailIndex))
        Case "packed", "__packed__": entry.isPacked = -1
        End Select
    Next

    Dim tailParts() As String
    Dim tailAliasNames() As String
    Dim tailBindingOrders() As String
    Dim tailPartCount As Long
    Dim recordTailParsed As Long = 0
    If entry.recordTail <> "" Then
        recordTailParsed = ParseGenericRecordTypedefTail( _
            entry.recordTail, tailParts(), tailAliasNames(), _
            tailBindingOrders(), tailPartCount)
    End If
    If entry.isTypedef <> 0 AndAlso entry.recordTail <> "" Then
        If recordTailParsed = 0 Then
            entry.unsupported = -1
        Else
            For tailPartIndex As Long = 0 To tailPartCount - 1
                If tailBindingOrders(tailPartIndex) = "" Then
                    entry.recordAlias = tailAliasNames(tailPartIndex)
                    Exit For
                End If
            Next
        End If
    End If
    If entry.recordTag = "" AndAlso entry.recordAlias = "" AndAlso _
       entry.recordTail <> "" AndAlso recordTailParsed <> 0 Then
        entry.recordAlias = C2fbAnonymousRecordAlias( _
            entry.recordKind, entry.inputOrder)
    End If
    Dim tailAlignment As Long
    If C2fbRecordHasUnsupportedAlignment( _
        entry.recordPrefix, entry.recordTail, entry.recordAlignment, _
        tailAlignment) <> 0 Then _
        entry.unsupported = -1
    If tailAlignment <> 0 Then
        If entry.isTypedef <> 0 AndAlso entry.recordAlias <> "" AndAlso _
           tailPartCount = 1 Then
            If entry.recordTag = "" OrElse entry.recordAlias = entry.recordTag Then
                ' The typedef is the record's public type, so its alignment
                ' belongs on the backing record layout itself.
                If tailAlignment > entry.recordAlignment Then _
                    entry.recordAlignment = tailAlignment
            Else
                ' A distinct C typedef may raise alignment without changing
                ' the underlying record's size.
                entry.typedefAlignment = tailAlignment
            End If
        Else
            entry.unsupported = -1
        End If
    End If
    If entry.recordAlignment > 0 AndAlso _
       (entry.isPacked <> 0 OrElse entry.packValue > 0) Then _
        entry.unsupported = -1
    ' Anonymous enum members remain visible C identifiers without a tag or typedef.
    If entry.recordTag = "" AndAlso entry.recordAlias = "" AndAlso _
       entry.recordKind <> C2FB_RECORD_ENUM Then _
        entry.unsupported = -1
    If entry.hasNestedRecord <> 0 AndAlso _
       NormalizeNestedTaggedRecordBody(sourceUnit, entry, 0) = 0 Then _
        entry.unsupported = -1
    If entry.packValue < 0 OrElse _
       (entry.packValue <> 0 AndAlso entry.packValue <> 1 AndAlso _
        entry.packValue <> 2 AndAlso entry.packValue <> 4 AndAlso _
        entry.packValue <> 8) Then entry.unsupported = -1

    sourceItem.declaration = entry
    sourceItem.body = ""
    sourceUnit.diagnosticState.currentSourceLocation = entry.sourceSpan.startLocation
End Sub

Declare Function C2fbHasTopLevelAssignment( _
    ByVal sourceText As String _
) As Long

Private Sub AppendC2fbLibraryPragmaInSourceUnit( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByVal libraryName As String, _
    ByRef sourceLocation As C2fbSourceLocationModel _
)
    If sourceUnit.libraryPragmaCount >= MAX_FUNCTIONS Then _
        ReportError("source unit exceeds the configured library pragma limit")
    If sourceUnit.libraryPragmaCount = 0 Then
        ReDim sourceUnit.libraryPragmas(0 To 15)
    ElseIf sourceUnit.libraryPragmaCount > _
           UBound(sourceUnit.libraryPragmas) Then
        ReDim Preserve sourceUnit.libraryPragmas( _
            0 To UBound(sourceUnit.libraryPragmas) * 2 + 1)
    End If
    sourceUnit.libraryPragmas(sourceUnit.libraryPragmaCount).libraryName = libraryName
    sourceUnit.libraryPragmas(sourceUnit.libraryPragmaCount).sourceLocation = sourceLocation
    sourceUnit.libraryPragmaCount += 1
End Sub

Private Function IsC2fbDiagnosticPragma( _
    ByVal directiveText As String _
) As Long
    ' GCC and Clang diagnostic pragmas affect warnings, not generated code.
    Dim normalizedDirective As String = LCase(Trim(directiveText))
    Dim gccPrefix As String = "pragma gcc diagnostic"
    Dim clangPrefix As String = "pragma clang diagnostic"
    If Left(normalizedDirective, Len(gccPrefix)) = gccPrefix Then
        If Len(normalizedDirective) = Len(gccPrefix) OrElse _
           IsSpaceByte(Asc(normalizedDirective, Len(gccPrefix) + 1)) <> 0 Then _
            Return -1
    End If
    If Left(normalizedDirective, Len(clangPrefix)) = clangPrefix Then
        If Len(normalizedDirective) = Len(clangPrefix) OrElse _
           IsSpaceByte(Asc(normalizedDirective, Len(clangPrefix) + 1)) <> 0 Then _
            Return -1
    End If
    Return 0
End Function

Private Function IsIncludedPreprocessedCSource(ByVal sourcePath As String) As Long
    ' Bison and Flex line markers retain their source suffix after C preprocessing.
    Dim normalizedPath As String = LCase(sourcePath)
    If Right(normalizedPath, 2) = ".c" OrElse _
       Right(normalizedPath, 2) = ".y" OrElse _
       Right(normalizedPath, 2) = ".l" Then Return -1
    Return 0
End Function

Private Function NextC2fbSourceItem( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByRef scanner As C2fbFunctionScanner, _
    ByRef sourceItem As C2fbSourceItemModel _
) As Long
    If scanner.physicalLineReader.textReader.isOpen = 0 OrElse _
       scanner.isFinished <> 0 Then Return 0

    Erase sourceItem.declaration.tokens
    sourceItem.declaration.text = ""
    sourceItem.declaration.sourceName = ""
    sourceItem.declaration.sourceSpan.startLocation.path = ""
    sourceItem.declaration.sourceSpan.startLocation.line = 0
    sourceItem.declaration.sourceSpan.startLocation.column = 0
    sourceItem.declaration.sourceSpan.endLocation.path = ""
    sourceItem.declaration.sourceSpan.endLocation.line = 0
    sourceItem.declaration.sourceSpan.endLocation.column = 0
    sourceItem.declaration.entryKind = C2FB_DECLARATION_PLAIN
    sourceItem.declaration.isFunctionDefinition = 0
    sourceItem.declaration.inputOrder = 0
    sourceItem.declaration.removeFromGenericHeader = 0
    sourceItem.declaration.isConditional = 0
    sourceItem.declaration.hasDirectives = 0
    sourceItem.declaration.isHeaderBody = 0
    sourceItem.declaration.recordPrefix = ""
    sourceItem.declaration.recordBody = ""
    sourceItem.declaration.recordTail = ""
    sourceItem.declaration.recordTag = ""
    sourceItem.declaration.recordAlias = ""
    Erase sourceItem.declaration.removedDeclarators
    sourceItem.declaration.removedDeclaratorCount = 0
    Erase sourceItem.declaration.removedEnumMembers
    sourceItem.declaration.removedEnumMemberCount = 0
    sourceItem.declaration.recordKind = C2FB_RECORD_KIND_NONE
    sourceItem.declaration.isTypedef = 0
    sourceItem.declaration.isPacked = 0
    sourceItem.declaration.packValue = 0
    sourceItem.declaration.hasNestedRecord = 0
    sourceItem.declaration.unsupported = 0
    sourceItem.body = ""
    sourceItem.declaration.tokenCount = 0

    While scanner.isFinished = 0
        If scanner.linePosition = 0 Then
            If ReadC2fbPhysicalSourceLine( _
                scanner.physicalLineReader, scanner.lineText) = 0 Then
                CloseC2fbFunctionScanner(scanner)
                Return 0
            End If
            If C2fbScannerHasSourceLineLocations(scanner) <> 0 Then
                sourceUnit.diagnosticState.currentSourceLocation.line = _
                    scanner.physicalLineReader.lineNumber
            Else
                sourceUnit.diagnosticState.currentSourceLocation.line = 0
                sourceUnit.diagnosticState.currentSourceLocation.column = 0
            End If
            If scanner.skipDirectiveContinuation <> 0 Then
                scanner.skipDirectiveContinuation = _
                    HasC2fbLineContinuation(scanner.lineText)
                Continue While
            End If

            Dim trimmedLine As String = LTrim(scanner.lineText)
            ' C linkage braces wrap declarations; they are not a declaration body.
            If scanner.options.recognizeCLinkageBlocks <> 0 AndAlso _
               scanner.braceDepth = 0 AndAlso _
               InStr(scanner.lineText, "extern " & Chr(34) & "C" & Chr(34)) <> 0 Then
                If InStr(scanner.lineText, "{") <> 0 Then _
                    scanner.insideCLinkage = -1
                scanner.linePosition = 0
                Continue While
            End If
            If scanner.options.recognizeCLinkageBlocks <> 0 AndAlso _
               scanner.braceDepth = 0 AndAlso _
               scanner.insideCLinkage <> 0 AndAlso Trim(trimmedLine) = "}" Then
                scanner.insideCLinkage = 0
                scanner.linePosition = 0
                Continue While
            End If
            If Left(trimmedLine, 1) = "#" Then
                scanner.skipDirectiveContinuation = _
                    HasC2fbLineContinuation(scanner.lineText)
                Dim directiveText As String = LTrim(Mid(trimmedLine, 2))
                If scanner.options.sourceMapMode <> C2FB_SOURCE_MAP_DISABLED Then
                    Dim markerLocation As C2fbSourceLocationModel
                    If CPreprocessorLineMarkerLocation( _
                        directiveText, markerLocation) <> 0 Then
                        scanner.currentSourcePath = markerLocation.path
                        scanner.currentSourceIsRoot = CSourcePathMatches( _
                            scanner.rootSourcePath, markerLocation.path)
                        markerLocation.line -= 1
                        scanner.physicalLineReader.lineNumber = markerLocation.line
                        If scanner.physicalLineReader.lineNumber < 0 Then _
                            scanner.physicalLineReader.lineNumber = 0
                        markerLocation.line = scanner.physicalLineReader.lineNumber
                        sourceUnit.diagnosticState.currentSourceLocation = markerLocation
                        If C2fbScannerHasSourceLineLocations(scanner) = 0 Then
                            sourceUnit.diagnosticState.currentSourceLocation.line = 0
                            sourceUnit.diagnosticState.currentSourceLocation.column = 0
                        End If
                        If scanner.insideFunction <> 0 AndAlso _
                           scanner.options.retainFunctionBodies <> 0 Then
                            scanner.body &= " "
                        ElseIf scanner.braceDepth = 0 Then
                            scanner.declaration &= " "
                        ElseIf scanner.skipDeclarationTail = 2 Then
                            scanner.declaration &= " "
                        ElseIf scanner.recordOpen <> 0 Then
                            If scanner.recordClosed <> 0 Then
                                scanner.recordTail &= " "
                            Else
                                scanner.recordBody &= " "
                            End If
                        End If
                        Continue While
                    End If
                End If

                Dim directiveWord As String = ""
                Dim directivePosition As Long = 1
                While directivePosition <= Len(directiveText) AndAlso _
                      IsIdentifierPart(Asc(directiveText, directivePosition)) <> 0
                    directiveWord &= Mid(directiveText, directivePosition, 1)
                    directivePosition += 1
                Wend
                Select Case LCase(directiveWord)
                Case "if", "ifdef", "ifndef"
                    If scanner.options.resetConditionalBranches <> 0 Then
                        If scanner.conditionalDepth >= MAX_C2FB_FUNCTION_CONDITIONAL_DEPTH Then _
                            ReportError("C preprocessor nesting exceeds the scanner limit")
                        With scanner.conditionalBranches(scanner.conditionalDepth)
                            .declaration = scanner.declaration
                            .declarationStartLocation = scanner.declarationStartLocation
                            .declarationOriginCaptured = scanner.declarationOriginCaptured
                            .braceDepth = scanner.braceDepth
                            .insideFunction = scanner.insideFunction
                            .insideCLinkage = scanner.insideCLinkage
                            .skipDeclarationTail = scanner.skipDeclarationTail
                            .body = scanner.body
                        End With
                    End If
                    scanner.conditionalDepth += 1
                Case "elif", "else"
                    If scanner.options.resetConditionalBranches <> 0 AndAlso _
                       scanner.conditionalDepth > 0 Then
                        With scanner.conditionalBranches(scanner.conditionalDepth - 1)
                            scanner.declaration = .declaration
                            scanner.declarationStartLocation = .declarationStartLocation
                            scanner.declarationOriginCaptured = .declarationOriginCaptured
                            scanner.braceDepth = .braceDepth
                            scanner.insideFunction = .insideFunction
                            scanner.insideCLinkage = .insideCLinkage
                            scanner.skipDeclarationTail = .skipDeclarationTail
                            scanner.body = .body
                        End With
                    End If
                Case "endif"
                    If scanner.conditionalDepth > 0 Then _
                        scanner.conditionalDepth -= 1
                End Select
                UpdateC2fbPackState( _
                    scanner.lineText, scanner.packValue, _
                    scanner.packStack(), scanner.packDepth)
                If scanner.options.collectLibraryPragmas = _
                   C2FB_LIBRARY_PRAGMAS_COLLECT Then
                    Dim libraryName As String
                    If ParseGenericLibraryPragma( _
                        scanner.lineText, libraryName) <> 0 Then _
                        AppendC2fbLibraryPragmaInSourceUnit( _
                            sourceUnit, libraryName, _
                            sourceUnit.diagnosticState.currentSourceLocation)
                End If
                If scanner.insideFunction <> 0 AndAlso _
                   IsC2fbDiagnosticPragma(directiveText) = 0 Then _
                    sourceItem.declaration.hasDirectives = -1
                If scanner.recordOpen <> 0 Then
                    If scanner.recordClosed <> 0 Then
                        scanner.recordTail &= " "
                    Else
                        scanner.recordBody &= " "
                    End If
                ElseIf scanner.skipDeclarationTail = 2 Then
                    scanner.declaration &= " "
                End If
                Continue While
            End If
            scanner.linePosition = 1
        End If

        If scanner.linePosition > Len(scanner.lineText) Then
            If scanner.insideFunction <> 0 AndAlso _
               scanner.options.retainFunctionBodies <> 0 Then _
                scanner.body &= " "
            If scanner.recordClosed <> 0 Then
                scanner.recordTail &= " "
            ElseIf scanner.recordOpen <> 0 AndAlso scanner.braceDepth > 0 Then
                scanner.recordBody &= " "
            ElseIf scanner.skipDeclarationTail = 2 Then
                scanner.declaration &= " "
            ElseIf scanner.braceDepth = 0 Then
                scanner.declaration &= " "
            End If
            scanner.linePosition = 0
            Continue While
        End If

        Dim currentByte As Long = Asc( _
            scanner.lineText, scanner.linePosition)
        scanner.linePosition += 1
        If scanner.quote <> 0 Then
            If scanner.insideFunction <> 0 AndAlso _
               scanner.options.retainFunctionBodies <> 0 Then _
                scanner.body &= Chr(currentByte)
            If scanner.recordOpen <> 0 Then
                If scanner.recordClosed <> 0 Then
                    scanner.recordTail &= Chr(currentByte)
                Else
                    scanner.recordBody &= Chr(currentByte)
                End If
            ElseIf scanner.skipDeclarationTail = 2 Then
                scanner.declaration &= Chr(currentByte)
            ElseIf scanner.insideFunction = 0 AndAlso _
                   scanner.braceDepth = 0 AndAlso _
                   scanner.skipDeclarationTail = 0 Then
                scanner.declaration &= Chr(currentByte)
            End If
            If scanner.escaped <> 0 Then
                scanner.escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                scanner.escaped = -1
            ElseIf currentByte = scanner.quote Then
                scanner.quote = 0
            End If
        ElseIf currentByte = Asc(Chr(34)) OrElse _
               currentByte = Asc("'") Then
            scanner.quote = currentByte
            If scanner.insideFunction <> 0 AndAlso _
               scanner.options.retainFunctionBodies <> 0 Then _
                scanner.body &= Chr(currentByte)
            If scanner.recordOpen <> 0 Then
                If scanner.recordClosed <> 0 Then
                    scanner.recordTail &= Chr(currentByte)
                Else
                    scanner.recordBody &= Chr(currentByte)
                End If
            ElseIf scanner.skipDeclarationTail = 2 Then
                scanner.declaration &= Chr(currentByte)
            ElseIf scanner.insideFunction = 0 AndAlso _
                   scanner.braceDepth = 0 AndAlso _
                   scanner.skipDeclarationTail = 0 Then
                ' Declaration string literals can carry GNU assembler symbol
                ' names, so keep them in the text passed to later C parsers.
                scanner.declaration &= Chr(currentByte)
            End If
        ElseIf scanner.braceDepth = 0 Then
            If scanner.declarationBraceDepth > 0 Then
                UpdateC2fbDeclarationGroupDepth(scanner, currentByte)
                If currentByte = Asc("{") Then
                    scanner.declarationBraceDepth += 1
                ElseIf currentByte = Asc("}") Then
                    scanner.declarationBraceDepth -= 1
                End If
                scanner.declaration &= Chr(currentByte)
                Continue While
            End If
            UpdateC2fbDeclarationGroupDepth(scanner, currentByte)
            If scanner.recordClosed <> 0 Then
                If currentByte = Asc(";") Then
                    SetC2fbScannedRecordModel( _
                        sourceUnit, scanner, sourceItem)
                    ResetC2fbScannedRecordState(scanner)
                    scanner.declaration = ""
                    scanner.declarationStartLocation.line = 0
                    scanner.declarationStartLocation.path = ""
                    scanner.declarationStartLocation.column = 0
                    scanner.declarationOriginCaptured = 0
                    scanner.declarationParenDepth = 0
                    scanner.declarationBracketDepth = 0
                    scanner.declarationBraceDepth = 0
                    Return -1
                End If
                scanner.recordTail &= Chr(currentByte)
                Continue While
            End If
            ' A record alias or aggregate initializer name is part of the brace
            ' group, not another declaration after its closing brace.
            If scanner.skipDeclarationTail = 1 Then
                If currentByte = Asc(";") Then
                    scanner.skipDeclarationTail = 0
                    scanner.declaration = ""
                    scanner.declarationStartLocation.line = 0
                    scanner.declarationStartLocation.path = ""
                    scanner.declarationStartLocation.column = 0
                    scanner.declarationOriginCaptured = 0
                    scanner.declarationParenDepth = 0
                    scanner.declarationBracketDepth = 0
                    scanner.declarationBraceDepth = 0
                End If
                Continue While
            End If
            If currentByte = Asc("{") Then
                If scanner.declarationParenDepth > 0 OrElse _
                   scanner.declarationBracketDepth > 0 Then
                    ' Compound literals inside declarators are not function bodies.
                    scanner.declarationBraceDepth = 1
                    scanner.declaration &= Chr(currentByte)
                    Continue While
                End If
                Dim declarationTokens() As String
                Dim declarationTokenCount As Long
                Dim normalizedDeclaration As String = _
                    StripCFunctionAttributes(scanner.declaration)
                TokenizeCDeclaration( _
                    normalizedDeclaration, declarationTokens(), _
                    declarationTokenCount)
                Dim declarationIsStatic As Long = 0
                Dim declarationIsInline As Long = 0
                For tokenIndex As Long = 0 To declarationTokenCount - 1
                    If declarationTokens(tokenIndex) = "static" Then _
                        declarationIsStatic = -1
                    If declarationTokens(tokenIndex) = "inline" OrElse _
                       declarationTokens(tokenIndex) = "__inline" OrElse _
                       declarationTokens(tokenIndex) = "__inline__" Then _
                        declarationIsInline = -1
                Next
                Dim isIncludedCSourceBody As Long = CInt( _
                    scanner.currentSourceIsRoot = 0 AndAlso _
                    scanner.options.collectIncludedCSourceBodies <> 0 AndAlso _
                    IsIncludedPreprocessedCSource( _
                        scanner.currentSourcePath) <> 0) * -1
                Dim selectedHeaderBody As Long = 0
                If scanner.options.includeHeaderBodyNames <> "" AndAlso _
                   scanner.options.sourceMapMode <> C2FB_SOURCE_MAP_DISABLED AndAlso _
                   scanner.currentSourceIsRoot = 0 AndAlso _
                   isIncludedCSourceBody = 0 Then
                    Dim headerBodyPrototype As C2fbSourceItemModel
                    If ParseScannedCFunctionDeclaration( _
                        sourceUnit, scanner, headerBodyPrototype, _
                        scanner.declaration, 0) <> 0 Then
                        selectedHeaderBody = C2fbDelimitedNameListContains( _
                            scanner.options.includeHeaderBodyNames, _
                            headerBodyPrototype.declaration.sourceName)
                    End If
                End If
                Dim sourceDefinesBody As Long = CInt( _
                    scanner.options.sourceMapMode = C2FB_SOURCE_MAP_DISABLED OrElse _
                    scanner.currentSourceIsRoot <> 0 OrElse _
                    isIncludedCSourceBody <> 0 OrElse _
                    declarationIsStatic <> 0 OrElse _
                    (scanner.options.collectHeaderInlineBodies <> 0 AndAlso _
                     declarationIsInline <> 0) OrElse _
                    selectedHeaderBody <> 0)
                Dim functionFound As Long = 0
                Dim headerPrototypeFound As Long = 0
                If scanner.options.collectFunctionDefinitions <> 0 AndAlso _
                   sourceDefinesBody <> 0 Then
                    functionFound = ParseScannedCFunctionDeclaration( _
                        sourceUnit, scanner, sourceItem, _
                        scanner.declaration, -1)
                ElseIf scanner.options.collectFunctionDefinitions <> 0 AndAlso _
                       declarationIsInline <> 0 AndAlso _
                       declarationIsStatic = 0 Then
                    ' An external inline definition also declares its function.
                    ' Keep the signature when its header body is not selected;
                    ' another translation unit supplies the external symbol.
                    headerPrototypeFound = ParseScannedCFunctionDeclaration( _
                        sourceUnit, scanner, sourceItem, _
                        scanner.declaration & ";", 0)
                End If
                If functionFound <> 0 Then
                    scanner.insideFunction = -1
                    scanner.body = ""
                Else
                    scanner.insideFunction = 0
                    Dim hasInitializer As Long = _
                        C2fbHasTopLevelAssignment(scanner.declaration)
                    If scanner.options.collectRecordModels <> 0 Then
                        Dim recordTag As String
                        Dim recordTypedef As Long
                        Dim recordPacked As Long
                        Dim recordKind As C2fbRecordKind = C2fbRecordKindFromPrefix( _
                            scanner.declaration, recordTag, recordTypedef, recordPacked)
                        If recordKind <> C2FB_RECORD_KIND_NONE Then
                            scanner.recordOpen = -1
                            scanner.recordKind = recordKind
                            scanner.recordTag = recordTag
                            scanner.recordTypedef = recordTypedef
                            scanner.recordPacked = recordPacked
                            scanner.recordPackValue = scanner.packValue
                            scanner.recordSourceLocation = scanner.declarationStartLocation
                            scanner.recordInputOrder = scanner.declarationInputOrder
                            If C2fbScannerHasSourceLineLocations(scanner) <> 0 AndAlso _
                               scanner.recordSourceLocation.line = 0 Then _
                                scanner.recordSourceLocation.line = scanner.physicalLineReader.lineNumber
                            scanner.recordPrefix = Trim(scanner.declaration)
                            scanner.recordBody = ""
                            scanner.recordTail = ""
                            scanner.recordNested = 0
                            scanner.skipDeclarationTail = 0
                        ElseIf hasInitializer <> 0 Then
                            ' Keep a file-scope aggregate initializer attached
                            ' to its object declaration for later lowering.
                            scanner.skipDeclarationTail = 2
                            scanner.declaration &= "{"
                        Else
                            scanner.skipDeclarationTail = 0
                        End If
                    Else
                        If hasInitializer <> 0 Then
                            scanner.skipDeclarationTail = 2
                            scanner.declaration &= "{"
                        Else
                            scanner.skipDeclarationTail = 0
                        End If
                    End If
                End If
                scanner.braceDepth = 1
                scanner.declarationParenDepth = 0
                scanner.declarationBracketDepth = 0
                scanner.declarationBraceDepth = 0
                If scanner.skipDeclarationTail <> 2 Then
                    scanner.declaration = ""
                    scanner.declarationStartLocation.line = 0
                    scanner.declarationStartLocation.path = ""
                    scanner.declarationStartLocation.column = 0
                    scanner.declarationOriginCaptured = 0
                End If
                If headerPrototypeFound <> 0 Then Return -1
            ElseIf currentByte = Asc(";") Then
                If scanner.declarationParenDepth <> 0 OrElse _
                   scanner.declarationBracketDepth <> 0 Then
                    scanner.declaration &= Chr(currentByte)
                    Continue While
                End If
                Dim declarationText As String = Trim(scanner.declaration)
                Dim declarationStartLocation As C2fbSourceLocationModel
                declarationStartLocation = scanner.declarationStartLocation
                Dim isFunctionPrototype As Long = ParseScannedCFunctionDeclaration( _
                    sourceUnit, scanner, sourceItem, _
                    declarationText & ";", 0)
                scanner.declaration = ""
                scanner.declarationStartLocation.line = 0
                scanner.declarationStartLocation.path = ""
                scanner.declarationStartLocation.column = 0
                scanner.declarationOriginCaptured = 0
                scanner.declarationParenDepth = 0
                scanner.declarationBracketDepth = 0
                scanner.declarationBraceDepth = 0
                If isFunctionPrototype <> 0 Then Return -1
                If declarationText <> "" Then
                    sourceItem.declaration.text = declarationText
                    sourceItem.declaration.entryKind = C2FB_DECLARATION_PLAIN
                    sourceItem.declaration.inputOrder = scanner.declarationInputOrder
                    sourceItem.declaration.sourceSpan.startLocation = declarationStartLocation
                    If sourceItem.declaration.sourceSpan.startLocation.path = "" Then _
                        sourceItem.declaration.sourceSpan.startLocation.path = _
                            sourceUnit.diagnosticState.currentSourceLocation.path
                    If C2fbScannerHasSourceLineLocations(scanner) <> 0 AndAlso _
                       sourceItem.declaration.sourceSpan.startLocation.line = 0 Then _
                        sourceItem.declaration.sourceSpan.startLocation.line = scanner.physicalLineReader.lineNumber
                    sourceItem.declaration.sourceSpan.endLocation = _
                        sourceUnit.diagnosticState.currentSourceLocation
                    If C2fbScannerHasSourceLineLocations(scanner) <> 0 Then _
                        sourceItem.declaration.sourceSpan.endLocation.line = _
                            scanner.physicalLineReader.lineNumber
                    If C2fbScannerHasSourceLineLocations(scanner) = 0 OrElse _
                       scanner.options.sourceMapMode <> C2FB_SOURCE_MAP_DISABLED Then _
                        sourceItem.declaration.sourceSpan.startLocation.column = 0
                    sourceItem.declaration.isConditional = _
                        CInt(scanner.conditionalDepth <> 0)
                    Return -1
                End If
            Else
                If scanner.declarationOriginCaptured = 0 AndAlso _
                   IsSpaceByte(currentByte) = 0 Then
                    scanner.declarationStartLocation.path = sourceUnit.diagnosticState.currentSourceLocation.path
                    scanner.declarationInputOrder = _
                        CLngInt(scanner.physicalLineReader.textReader.physicalLineNumber) * _
                        C2FB_SOURCE_ORDER_LINE_SCALE + _
                        CLngInt(scanner.linePosition - 1)
                    If C2fbScannerHasSourceLineLocations(scanner) <> 0 Then
                        scanner.declarationStartLocation.line = _
                            scanner.physicalLineReader.lineNumber
                        scanner.declarationStartLocation.column = scanner.linePosition - 1
                    Else
                        scanner.declarationStartLocation.line = 0
                        scanner.declarationStartLocation.column = 0
                    End If
                    scanner.declarationOriginCaptured = -1
                End If
                scanner.declaration &= Chr(currentByte)
            End If
        ElseIf currentByte = Asc("{") Then
            scanner.braceDepth += 1
            If scanner.insideFunction <> 0 AndAlso _
               scanner.options.retainFunctionBodies <> 0 Then _
                scanner.body &= "{"
            If scanner.recordOpen <> 0 AndAlso scanner.recordClosed = 0 Then
                scanner.recordNested = -1
                scanner.recordBody &= "{"
            ElseIf scanner.recordOpen <> 0 AndAlso scanner.recordClosed <> 0 Then
                ' Keep a file-scope aggregate initializer attached to the
                ' variable tail after an inline record definition.
                scanner.recordTail &= "{"
            ElseIf scanner.skipDeclarationTail = 2 Then
                scanner.declaration &= "{"
            End If
        ElseIf currentByte = Asc("}") Then
            scanner.braceDepth -= 1
            If scanner.braceDepth = 0 Then
                If scanner.insideFunction <> 0 Then
                    sourceItem.body = scanner.body
                    sourceItem.declaration.sourceSpan.endLocation = _
                        sourceUnit.diagnosticState.currentSourceLocation
                    If C2fbScannerHasSourceLineLocations(scanner) <> 0 Then _
                        sourceItem.declaration.sourceSpan.endLocation.line = _
                            scanner.physicalLineReader.lineNumber
                    scanner.insideFunction = 0
                    scanner.body = ""
                    scanner.declaration = ""
                    scanner.declarationStartLocation.line = 0
                    scanner.declarationStartLocation.path = ""
                    scanner.declarationStartLocation.column = 0
                    scanner.declarationOriginCaptured = 0
                    Return -1
                ElseIf scanner.recordOpen <> 0 Then
                    scanner.recordClosed = -1
                ElseIf scanner.skipDeclarationTail = 2 Then
                    scanner.declaration &= "}"
                    scanner.skipDeclarationTail = 0
                Else
                    scanner.declaration = ""
                    scanner.declarationStartLocation.line = 0
                    scanner.declarationStartLocation.path = ""
                    scanner.declarationStartLocation.column = 0
                    scanner.declarationOriginCaptured = 0
                End If
            ElseIf scanner.insideFunction <> 0 Then
                If scanner.options.retainFunctionBodies <> 0 Then _
                    scanner.body &= "}"
            ElseIf scanner.recordOpen <> 0 AndAlso scanner.recordClosed = 0 Then
                scanner.recordBody &= "}"
            ElseIf scanner.recordOpen <> 0 AndAlso scanner.recordClosed <> 0 Then
                scanner.recordTail &= "}"
            ElseIf scanner.skipDeclarationTail = 2 Then
                scanner.declaration &= "}"
            End If
        ElseIf scanner.insideFunction <> 0 Then
            If scanner.options.retainFunctionBodies <> 0 Then _
                scanner.body &= Chr(currentByte)
        ElseIf scanner.recordOpen <> 0 AndAlso scanner.recordClosed = 0 Then
            scanner.recordBody &= Chr(currentByte)
        ElseIf scanner.skipDeclarationTail = 2 Then
            scanner.declaration &= Chr(currentByte)
        End If
    Wend
    Return 0
End Function

Private Function C2fbHasTopLevelAssignment( _
    ByVal sourceText As String _
) As Long
    ' Do not mistake comparisons or assignments inside if/for groups for
    ' aggregate initializers before a brace.
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    For position As Long = 1 To Len(sourceText)
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
        ElseIf currentByte = Asc("(") Then
            parenDepth += 1
        ElseIf currentByte = Asc(")") Then
            If parenDepth > 0 Then parenDepth -= 1
        ElseIf currentByte = Asc("[") Then
            bracketDepth += 1
        ElseIf currentByte = Asc("]") Then
            If bracketDepth > 0 Then bracketDepth -= 1
        ElseIf currentByte = Asc("=") AndAlso _
               parenDepth = 0 AndAlso bracketDepth = 0 Then
            Dim previousByte As Long = 0
            Dim nextByte As Long = 0
            If position > 1 Then previousByte = Asc(sourceText, position - 1)
            If position < Len(sourceText) Then nextByte = Asc(sourceText, position + 1)
            If previousByte <> Asc("=") AndAlso previousByte <> Asc("!") AndAlso _
               previousByte <> Asc("<") AndAlso previousByte <> Asc(">") AndAlso _
               nextByte <> Asc("=") Then Return -1
        End If
    Next
    Return 0
End Function

Private Sub CollectC2fbBlockLocalRecordDeclarationsInSourceUnit( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByVal bodyText As String, ByVal sourcePath As String _
)
    Dim position As Long = 1
    Dim declarationStart As Long = 1
    Dim quoteByte As Long = 0
    Dim blockDepth As Long = 1
    While position <= Len(bodyText)
        Dim currentByte As Long = Asc(bodyText, position)
        If quoteByte <> 0 Then
            If currentByte = Asc(Chr(92)) Then
                position += 1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
        ElseIf currentByte = Asc("'") OrElse _
               currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
        ElseIf currentByte = Asc("{") Then
            Dim declarationPrefix As String = Mid( _
                bodyText, declarationStart, position - declarationStart)
            Dim recordTag As String
            Dim isTypedef As Long
            Dim isPacked As Long
            Dim recordKind As C2fbRecordKind = C2fbRecordKindFromPrefix( _
                declarationPrefix, recordTag, isTypedef, isPacked)
            If recordKind <> C2FB_RECORD_KIND_NONE Then
                Dim finish As Long = position
                If ScanSimpleExpressionGroup( _
                    bodyText, finish, Asc("{"), Asc("}")) = 0 Then Exit While
                Dim tailEnd As Long = finish
                While tailEnd <= Len(bodyText) AndAlso _
                      Asc(bodyText, tailEnd) <> Asc(";")
                    tailEnd += 1
                Wend
                Dim recordTail As String = Trim(Mid( _
                    bodyText, finish, tailEnd - finish))
                Dim recordAlias As String
                If isTypedef <> 0 AndAlso recordTail <> "" Then
                    Dim tailTokens() As String
                    Dim tailCount As Long
                    TokenizeCDeclaration( _
                        StripCFunctionAttributes(recordTail), _
                        tailTokens(), tailCount)
                    For tailIndex As Long = 0 To tailCount - 1
                        If IsIdentifierToken(tailTokens(tailIndex)) <> 0 Then
                            recordAlias = tailTokens(tailIndex)
                            Exit For
                        End If
                    Next
                End If
                Dim declaration As C2fbDeclarationModel
                declaration.entryKind = C2FB_DECLARATION_RECORD
                declaration.text = Trim(declarationPrefix)
                declaration.sourceSpan.startLocation.path = sourcePath
                declaration.sourceSpan.startLocation.line = 0
                declaration.sourceSpan.endLocation.path = sourcePath
                declaration.sourceSpan.endLocation.line = 0
                declaration.recordPrefix = Trim(declarationPrefix)
                declaration.recordBody = Mid( _
                    bodyText, position + 1, finish - position - 2)
                declaration.recordTail = recordTail
                declaration.recordTag = recordTag
                declaration.recordAlias = recordAlias
                declaration.recordKind = recordKind
                declaration.isTypedef = isTypedef
                declaration.isPacked = isPacked
                declaration.isBlockLocal = -1
                AppendC2fbDeclarationInSourceUnit(sourceUnit, declaration)
                position = finish
                declarationStart = position
                Continue While
            End If
            If C2fbHasTopLevelAssignment(declarationPrefix) <> 0 Then
                Dim initializerEnd As Long = position
                If ScanSimpleExpressionGroup( _
                    bodyText, initializerEnd, Asc("{"), Asc("}")) = 0 Then Exit While
                position = initializerEnd
                declarationStart = position
                Continue While
            End If
            blockDepth += 1
            position += 1
            declarationStart = position
            Continue While
        ElseIf currentByte = Asc("}") Then
            If blockDepth > 1 Then blockDepth -= 1
            declarationStart = position + 1
        ElseIf currentByte = Asc(";") Then
            declarationStart = position + 1
        End If
        position += 1
    Wend
End Sub

Private Function CollectC2fbDeclarationsInSourceUnit( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByRef request As C2fbDeclarationScanRequestModel _
) As Long
    ResetC2fbDeclarationsInSourceUnit(sourceUnit, 256)
    sourceUnit.cppMode = request.cppMode
    sourceUnit.diagnosticState.currentSourceLocation.path = request.rootSourcePath
    sourceUnit.diagnosticState.currentSourceLocation.line = 0
    Dim scanner As C2fbFunctionScanner
    If OpenC2fbFunctionScanner(scanner, request) = 0 Then _
        ReportError("cannot read C declaration input: " & request.inputPath)

    Dim sourceItem As C2fbSourceItemModel
    While NextC2fbSourceItem(sourceUnit, scanner, sourceItem) <> 0
        If request.profile = C2FB_FUNCTION_SCAN_PROTOTYPES_ONLY Then
            If sourceItem.declaration.entryKind = C2FB_DECLARATION_FUNCTION AndAlso _
               sourceItem.declaration.isFunctionDefinition = 0 Then _
                AppendC2fbDeclarationInSourceUnit(sourceUnit, sourceItem.declaration)
            Continue While
        End If
        If C2fbScannerHasSourceLineLocations(scanner) <> 0 AndAlso _
           sourceItem.declaration.sourceSpan.startLocation.line = 0 AndAlso _
           (sourceItem.declaration.isFunctionDefinition = 0 OrElse _
            scanner.options.collectFunctionDefinitions = 0) Then _
            sourceItem.declaration.sourceSpan.startLocation.line = sourceUnit.diagnosticState.currentSourceLocation.line
        If sourceItem.declaration.isFunctionDefinition <> 0 Then
            If scanner.options.collectFunctionDefinitions <> 0 Then
                AppendC2fbDeclarationInSourceUnit(sourceUnit, sourceItem.declaration)
                CollectC2fbBlockLocalRecordDeclarationsInSourceUnit( _
                    sourceUnit, sourceItem.body, sourceItem.declaration.sourceSpan.startLocation.path)
            End If
            Continue While
        End If
        If sourceItem.declaration.entryKind <> C2FB_DECLARATION_PLAIN AndAlso _
           sourceItem.declaration.entryKind <> C2FB_DECLARATION_FUNCTION AndAlso _
           sourceItem.declaration.entryKind <> C2FB_DECLARATION_RECORD Then _
            Continue While
        AppendC2fbDeclarationInSourceUnit(sourceUnit, sourceItem.declaration)
    Wend
    CloseC2fbFunctionScanner(scanner)
    Return -1
End Function

/' end of c2fb_function_scanner.bi '/
