/'
    Project: C2FB shared C front end

    File: c2fb_macro_syntax.bi

    Purpose:

        Parse the shared syntax of object-like and function-like C directives.

    Responsibilities:

        - Parse define and undef directive names and replacement text.
        - Optionally tokenize replacement text through the common C lexer.
        - Reset and populate one shared macro-definition model.

    This file intentionally does NOT contain:

        - Logical-line reading, macro expansion, or target-specific policy.
        - SQLite constant conversion or generic-header output.
'/

Private Function ParseC2fbMacroDirective( _
    ByVal lineText As String, ByRef macro As C2fbMacroDefinitionModel, _
    ByVal tokenizeReplacement As Long = 0 _
) As Long
    macro.directive = ""
    macro.sourceName = ""
    macro.rawValue = ""
    macro.sourceLocation.path = ""
    macro.sourceLocation.line = 0
    macro.sourceLocation.column = 0
    macro.inputOrder = 0
    Erase macro.tokens
    macro.tokenCount = 0
    macro.functionLike = 0
    macro.continued = 0

    Dim position As Long = 1
    While position <= Len(lineText) AndAlso _
          IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position > Len(lineText) OrElse _
       Asc(lineText, position) <> Asc("#") Then Return 0
    position += 1
    While position <= Len(lineText) AndAlso _
          IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend

    Dim directiveStart As Long = position
    While position <= Len(lineText) AndAlso _
          IsIdentifierPart(Asc(lineText, position)) <> 0
        position += 1
    Wend
    macro.directive = LCase(Mid(lineText, directiveStart, position - directiveStart))
    If macro.directive <> "define" AndAlso macro.directive <> "undef" Then Return 0
    If position > Len(lineText) OrElse _
       IsSpaceByte(Asc(lineText, position)) = 0 Then Return 0
    While position <= Len(lineText) AndAlso _
          IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position > Len(lineText) OrElse _
       IsIdentifierStart(Asc(lineText, position)) = 0 Then Return 0

    Dim nameStart As Long = position
    position += 1
    While position <= Len(lineText) AndAlso _
          IsIdentifierPart(Asc(lineText, position)) <> 0
        position += 1
    Wend
    macro.sourceName = Mid(lineText, nameStart, position - nameStart)
    If macro.directive = "undef" Then Return -1

    If position <= Len(lineText) AndAlso _
       Asc(lineText, position) = Asc("(") Then
        macro.functionLike = -1
        macro.rawValue = Trim(Mid(lineText, position))
        If tokenizeReplacement <> 0 Then _
            TokenizeCDeclaration( _
                macro.rawValue, macro.tokens(), macro.tokenCount)
        Return -1
    End If
    While position <= Len(lineText) AndAlso _
          IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position <= Len(lineText) Then _
        macro.rawValue = Trim(Mid(lineText, position))
    If tokenizeReplacement <> 0 Then _
        TokenizeCDeclaration( _
            macro.rawValue, macro.tokens(), macro.tokenCount)
    Return -1
End Function

/' end of c2fb_macro_syntax.bi '/
