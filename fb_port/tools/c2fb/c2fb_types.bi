/'
    Project: C2FB

    File: c2fb_types.bi

    Purpose:

        Parse C type specifiers into a target-independent type shape.

    Responsibilities:

        - Collect the base spelling, pointer depth, and top-level constness.
        - Retain enum, struct, and union tags for profile-specific resolution.
        - Ignore storage, export, and calling-convention markers in type spans.
        - Flag syntax the generic ABI resolver cannot represent.

    This file intentionally does NOT contain:

        - SQLite or generic FreeBASIC type mappings.
        - Declarator parsing, parameter adjustment, or output formatting.
'/

' C permits primitive type specifiers in different orders. Normalize only
' complete built-in scalar spellings and leave typedef and tag names intact.

Private Function NormalizeCPrimitiveTypeSpelling( _
    ByVal sourceName As String _
) As String
    Dim signedCount As Long = 0
    Dim unsignedCount As Long = 0
    Dim shortCount As Long = 0
    Dim longCount As Long = 0
    Dim intCount As Long = 0
    Dim charCount As Long = 0
    Dim floatCount As Long = 0
    Dim doubleCount As Long = 0
    Dim voidCount As Long = 0
    Dim boolCount As Long = 0
    Dim position As Long = 1
    While position <= Len(sourceName)
        While position <= Len(sourceName) AndAlso _
              IsSpaceByte(Asc(sourceName, position)) <> 0
            position += 1
        Wend
        If position > Len(sourceName) Then Exit While
        Dim tokenStart As Long = position
        While position <= Len(sourceName) AndAlso _
              IsSpaceByte(Asc(sourceName, position)) = 0
            position += 1
        Wend
        Dim token As String = Mid(sourceName, tokenStart, position - tokenStart)
        Select Case token
        Case "signed": signedCount += 1
        Case "unsigned": unsignedCount += 1
        Case "short": shortCount += 1
        Case "long": longCount += 1
        Case "int": intCount += 1
        Case "char": charCount += 1
        Case "float": floatCount += 1
        Case "double": doubleCount += 1
        Case "void": voidCount += 1
        Case "_Bool", "bool": boolCount += 1
        Case Else
            Return sourceName
        End Select
    Wend

    If signedCount > 1 OrElse unsignedCount > 1 OrElse _
       (signedCount > 0 AndAlso unsignedCount > 0) OrElse _
       intCount > 1 OrElse shortCount > 1 OrElse longCount > 2 OrElse _
       charCount > 1 OrElse floatCount > 1 OrElse doubleCount > 1 OrElse _
       voidCount > 1 OrElse boolCount > 1 Then Return sourceName

    If voidCount = 1 Then
        If signedCount = 0 AndAlso unsignedCount = 0 AndAlso _
           shortCount = 0 AndAlso longCount = 0 AndAlso intCount = 0 AndAlso _
           charCount = 0 AndAlso floatCount = 0 AndAlso doubleCount = 0 AndAlso _
           boolCount = 0 Then Return "void"
        Return sourceName
    End If
    If boolCount = 1 Then
        If signedCount = 0 AndAlso unsignedCount = 0 AndAlso _
           shortCount = 0 AndAlso longCount = 0 AndAlso intCount = 0 AndAlso _
           charCount = 0 AndAlso floatCount = 0 AndAlso doubleCount = 0 Then _
            Return "_Bool"
        Return sourceName
    End If
    If charCount = 1 Then
        If shortCount = 0 AndAlso longCount = 0 AndAlso intCount = 0 AndAlso _
           floatCount = 0 AndAlso doubleCount = 0 Then
            If signedCount <> 0 Then Return "signed char"
            If unsignedCount <> 0 Then Return "unsigned char"
            Return "char"
        End If
        Return sourceName
    End If
    If floatCount = 1 Then
        If signedCount = 0 AndAlso unsignedCount = 0 AndAlso _
           shortCount = 0 AndAlso longCount = 0 AndAlso intCount = 0 AndAlso _
           doubleCount = 0 Then Return "float"
        Return sourceName
    End If
    If doubleCount = 1 Then
        If signedCount = 0 AndAlso unsignedCount = 0 AndAlso _
           shortCount = 0 AndAlso intCount = 0 AndAlso longCount <= 1 Then
            If longCount = 1 Then Return "long double"
            Return "double"
        End If
        Return sourceName
    End If

    If shortCount = 1 AndAlso longCount = 0 Then
        If signedCount <> 0 Then Return "signed short int"
        If unsignedCount <> 0 Then Return "unsigned short int"
        Return "short int"
    End If
    If shortCount <> 0 AndAlso longCount <> 0 Then Return sourceName
    If longCount = 1 OrElse longCount = 2 Then
        Dim lengthName As String = "long"
        If longCount = 2 Then lengthName &= " long"
        If signedCount <> 0 Then Return "signed " & lengthName & " int"
        If unsignedCount <> 0 Then Return "unsigned " & lengthName & " int"
        Return lengthName & " int"
    End If
    If longCount <> 0 OrElse shortCount <> 0 Then Return sourceName
    If signedCount <> 0 Then Return "signed int"
    If unsignedCount <> 0 Then Return "unsigned int"
    If intCount = 1 Then Return "int"
    Return sourceName
End Function

Private Function ParseCTypeModel( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef parsedType As C2fbCTypeModel _
) As Long
    parsedType.baseName = ""
    parsedType.pointerDepth = 0
    parsedType.isConst = 0
    parsedType.volatileMask = 0
    parsedType.isEnum = 0
    parsedType.isStruct = 0
    parsedType.isUnion = 0
    parsedType.hasUnsupportedSyntax = 0
    If firstToken > lastToken Then Return 0

    ' C11 spells an atomic type as _Atomic(type-name). Its storage layout is
    ' the layout of the wrapped type; atomic access semantics are lowered by
    ' the body adapter when that mode is enabled.
    Dim normalizedTokens(0 To lastToken - firstToken) As String
    Dim normalizedCount As Long = 0
    Dim hasAtomicTypeWrapper As Long = 0
    Dim tokenIndex As Long = firstToken
    While tokenIndex <= lastToken
        If tokens(tokenIndex) = "_Atomic" AndAlso _
           tokenIndex < lastToken AndAlso tokens(tokenIndex + 1) = "(" Then
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
            If nestingDepth <> 0 Then Return 0
            For innerToken As Long = tokenIndex + 2 To closingToken - 1
                normalizedTokens(normalizedCount) = tokens(innerToken)
                normalizedCount += 1
            Next
            tokenIndex = closingToken + 1
            hasAtomicTypeWrapper = -1
        Else
            normalizedTokens(normalizedCount) = tokens(tokenIndex)
            normalizedCount += 1
            tokenIndex += 1
        End If
    Wend
    If hasAtomicTypeWrapper <> 0 Then
        If normalizedCount <= 0 Then Return 0
        ReDim Preserve normalizedTokens(0 To normalizedCount - 1)
        Return ParseCTypeModel( _
            normalizedTokens(), 0, normalizedCount - 1, parsedType)
    End If

    Dim inArray As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        Dim tokenText As String = tokens(tokenIndex)
        ' GCC reserves these alternate keyword spellings for system headers.
        ' Canonicalize before mapping so declarations and body casts agree.
        If tokenText = "__signed" OrElse tokenText = "__signed__" Then _
            tokenText = "signed"
        Select Case tokenText
        Case "*"
            If inArray = 0 Then parsedType.pointerDepth += 1
        Case "["
            parsedType.pointerDepth += 1
            inArray = -1
        Case "]"
            inArray = 0
        Case "const"
            If parsedType.pointerDepth = 0 Then parsedType.isConst = -1
        Case "volatile", "__volatile", "__volatile__"
            parsedType.volatileMask = parsedType.volatileMask Or _
                (1 Shl parsedType.pointerDepth)
        Case "struct"
            parsedType.isStruct = -1
        Case "union"
            parsedType.isUnion = -1
        Case "enum"
            parsedType.isEnum = -1
        Case "auto", "static", "extern", "inline", "register", "restrict", _
             "__extension__", _
             "SQLITE_PRIVATE", "SQLITE_API", "SQLITE_EXTERN", _
             "__restrict", "__restrict__", "_Atomic", "cdecl", "__cdecl", _
             "__cdecl__", "stdcall", "__stdcall", "__stdcall__", "winapi", _
             "apientry", "ntapi", "far", "near"
            ' Storage, compiler-extension, export, and calling-convention markers
            ' are not type names.
        Case Else
            If inArray = 0 AndAlso IsAttributeToken(tokenText) = 0 Then
                If Len(tokenText) = 0 OrElse IsIdentifierStart(Asc(tokenText, 1)) = 0 Then
                    parsedType.hasUnsupportedSyntax = -1
                Else
                    For charIndex As Long = 2 To Len(tokenText)
                        If IsIdentifierPart(Asc(tokenText, charIndex)) = 0 Then
                            parsedType.hasUnsupportedSyntax = -1
                            Exit For
                        End If
                    Next
                End If
                If parsedType.baseName <> "" Then parsedType.baseName &= " "
                parsedType.baseName &= tokenText
            End If
        End Select
    Next

    If parsedType.baseName = "" Then Return 0
    parsedType.baseName = NormalizeCPrimitiveTypeSpelling(parsedType.baseName)
    Return -1
End Function

Private Function C2fbVolatileQualifierMask( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long _
) As Long
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel(tokens(), firstToken, lastToken, parsedType) = 0 OrElse _
       parsedType.hasUnsupportedSyntax <> 0 Then Return -1
    Return parsedType.volatileMask
End Function

/' end of c2fb_types.bi '/
