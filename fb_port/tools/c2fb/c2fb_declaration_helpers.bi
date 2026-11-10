/'
    Project: C2FB declaration helpers
    ----------------------------------

    File: c2fb_declaration_helpers.bi

    Purpose:

        Normalize compiler attributes in C declarations before shared
        declarator and prototype parsing.

    Responsibilities:

        - Remove attribute groups from declaration text.
        - Preserve calling-convention attributes as canonical tokens.
        - Remove the GNU __extension__ diagnostic marker without changing the declaration.

    This file intentionally does NOT contain:

        - C declarator parsing or prototype lowering.
        - Target ABI mapping or generated output formatting.
'/

Private Function StripCFunctionAttributes(ByVal declaration As String) As String
    Dim normalized As String = ""
    Dim position As Long = 1
    While position <= Len(declaration)
        If IsIdentifierStart(Asc(declaration, position)) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(declaration) AndAlso _
                  IsIdentifierPart(Asc(declaration, position)) <> 0
                position += 1
            Wend
            Dim token As String = Mid(declaration, tokenStart, position - tokenStart)
            If token = "__extension__" Then
                normalized &= " "
            ElseIf token = "__attribute" OrElse token = "__attribute__" OrElse _
                   token = "__declspec" Then
                Dim groupPosition As Long = position
                While groupPosition <= Len(declaration) AndAlso _
                      IsSpaceByte(Asc(declaration, groupPosition)) <> 0
                    groupPosition += 1
                Wend
                If groupPosition <= Len(declaration) AndAlso _
                   Asc(declaration, groupPosition) = Asc("(") Then
                    If ScanSimpleExpressionGroup(declaration, groupPosition, _
                                                 Asc("("), Asc(")")) = 0 Then Return ""
                    Dim attributeTokens() As String
                    Dim attributeTokenCount As Long
                    TokenizeCDeclaration( _
                        Mid(declaration, position, groupPosition - position), _
                        attributeTokens(), attributeTokenCount)
                    For attributeIndex As Long = 0 To attributeTokenCount - 1
                        Select Case LCase(attributeTokens(attributeIndex))
                        Case "stdcall", "__stdcall", "__stdcall__", "winapi", "apientry", "ntapi"
                            normalized &= " stdcall "
                        Case "cdecl", "__cdecl", "__cdecl__"
                            normalized &= " cdecl "
                        End Select
                    Next
                    normalized &= " "
                    position = groupPosition
                Else
                    normalized &= token
                End If
            Else
                normalized &= Mid(declaration, tokenStart, position - tokenStart)
            End If
        Else
            normalized &= Mid(declaration, position, 1)
            position += 1
        End If
    Wend
    Return normalized
End Function
/' end of c2fb_declaration_helpers.bi '/
