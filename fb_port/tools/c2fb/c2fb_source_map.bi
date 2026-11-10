/'
    Project: C2FB source mapping
    ---------------------------

    File: c2fb_source_map.bi

    Purpose:

        Parse preprocessor source markers and compare mapped source paths.

    Responsibilities:

        - Read GCC and Clang line-marker origins into one source-location model.
        - Compare root and marker paths with platform-aware normalization.

    This file intentionally does NOT contain:

        - Declaration scanning or source-map state transitions.
        - Compiler invocation or diagnostic formatting.
'/

' GCC/Clang -E line markers retain the origin of each flattened declaration.
Private Function CPreprocessorLineMarkerLocation( _
    ByVal directiveText As String, _
    ByRef sourceLocation As C2fbSourceLocationModel _
) As Long
    sourceLocation.path = ""
    sourceLocation.line = 0
    sourceLocation.column = 0
    sourceLocation.isSystemHeader = 0
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
    Dim digitStart As Long = position
    While position <= Len(directiveText) AndAlso _
          Asc(directiveText, position) >= Asc("0") AndAlso _
          Asc(directiveText, position) <= Asc("9")
        Dim digit As Long = Asc(directiveText, position) - Asc("0")
        If sourceLocation.line > (2147483647 - digit) \ 10 Then Return 0
        sourceLocation.line = sourceLocation.line * 10 + digit
        position += 1
    Wend
    If position = digitStart Then Return 0
    While position <= Len(directiveText) AndAlso _
          IsSpaceByte(Asc(directiveText, position)) <> 0
        position += 1
    Wend
    If position > Len(directiveText) OrElse _
       Asc(directiveText, position) <> Asc(Chr(34)) Then Return 0
    position += 1
    Dim closedQuote As Long = 0
    While position <= Len(directiveText)
        Dim currentByte As Long = Asc(directiveText, position)
        If currentByte = Asc(Chr(92)) AndAlso position < Len(directiveText) Then
            position += 1
            sourceLocation.path &= Chr(Asc(directiveText, position))
        ElseIf currentByte = Asc(Chr(34)) Then
            closedQuote = -1
            Exit While
        Else
            sourceLocation.path &= Chr(currentByte)
        End If
        position += 1
    Wend
    If closedQuote = 0 OrElse sourceLocation.path = "" Then Return 0

    position += 1
    While position <= Len(directiveText)
        While position <= Len(directiveText) AndAlso _
              IsSpaceByte(Asc(directiveText, position)) <> 0
            position += 1
        Wend
        If position > Len(directiveText) Then Exit While
        If Asc(directiveText, position) < Asc("0") OrElse _
           Asc(directiveText, position) > Asc("9") Then
            position += 1
            Continue While
        End If

        Dim flagValue As Long = 0
        While position <= Len(directiveText) AndAlso _
              Asc(directiveText, position) >= Asc("0") AndAlso _
              Asc(directiveText, position) <= Asc("9")
            Dim digit As Long = Asc(directiveText, position) - Asc("0")
            If flagValue > (2147483647 - digit) \ 10 Then Return 0
            flagValue = flagValue * 10 + digit
            position += 1
        Wend
        If flagValue = 3 Then sourceLocation.isSystemHeader = -1
    Wend
    Return -1
End Function

Private Function CSourcePathMatches( _
    ByVal inputPath As String, ByVal markerPath As String _
) As Long
    inputPath = Trim(inputPath)
    markerPath = Trim(markerPath)
    For position As Long = 1 To Len(inputPath)
        If Asc(inputPath, position) = Asc(Chr(92)) Then _
            Mid(inputPath, position, 1) = "/"
    Next
    For position As Long = 1 To Len(markerPath)
        If Asc(markerPath, position) = Asc(Chr(92)) Then _
            Mid(markerPath, position, 1) = "/"
    Next
    While Left(inputPath, 2) = "./"
        inputPath = Mid(inputPath, 3)
    Wend
    While Left(markerPath, 2) = "./"
        markerPath = Mid(markerPath, 3)
    Wend
#if defined(__FB_WIN32__)
    inputPath = LCase(inputPath)
    markerPath = LCase(markerPath)
#endif
    If inputPath = markerPath Then Return -1
    If Len(markerPath) > Len(inputPath) AndAlso _
       Right(markerPath, Len(inputPath)) = inputPath AndAlso _
       Mid(markerPath, Len(markerPath) - Len(inputPath), 1) = "/" Then Return -1
    Return 0
End Function
/' end of c2fb_source_map.bi '/
