' Project: GNU Coreutils FreeBASIC port
' File: coreutils_wc_neon_scalar.bi
' Purpose: Keep the ARM NEON wc helper available with scalar code.
' Responsibilities: Read bounded file-descriptor blocks and return the same
'                   line, byte, and error summary as the C helper.
' Does not contain command-line handling or word-count formatting.

Declare Function C2fbWcNeonRead CDecl Alias "read" (ByVal fd As c2fb_c_int, ByVal buffer As Any Ptr, ByVal count As c2fb_size_t) As c2fb_c_long
Declare Function C2fbWcNeonErrno CDecl Alias "__errno_location" () As c2fb_c_int Ptr

' Linux x86-64 EOVERFLOW. The port currently builds this helper for this ABI.
Private Const C2fbWcNeonEoverflow As c2fb_c_int = 75

Function wc_lines_neon CDecl Alias "wc_lines_neon" (ByVal fd As c2fb_c_int) As c2fb_wc_lines
    Dim lines As c2fb_int64 = 0
    Dim bytes As c2fb_int64 = 0
    Dim buffer(0 To c2fb_IO_BUFSIZE - 1) As UByte
    Dim bytesRead As c2fb_c_long
    Dim byteIndex As c2fb_size_t
    Dim readError As c2fb_c_int = 0
    Dim errnoAddress As c2fb_c_int Ptr

    While True
        bytesRead = C2fbWcNeonRead(fd, @buffer(0), c2fb_IO_BUFSIZE)
        If bytesRead <= 0 Then
            If bytesRead < 0 Then
                errnoAddress = C2fbWcNeonErrno()
                If errnoAddress <> 0 Then readError = *errnoAddress
            End If
            Return Type<c2fb_wc_lines>(readError, lines, bytes)
        End If

        If Cast(c2fb_uint64, bytesRead) > Cast(c2fb_uint64, &H7fffffffffffffff) - Cast(c2fb_uint64, bytes) Then
            errnoAddress = C2fbWcNeonErrno()
            If errnoAddress <> 0 Then *errnoAddress = C2fbWcNeonEoverflow
            Return Type<c2fb_wc_lines>(C2fbWcNeonEoverflow, lines, bytes)
        End If

        bytes += bytesRead
        For byteIndex = 0 To Cast(c2fb_size_t, bytesRead) - 1
            If buffer(byteIndex) = 10 Then lines += 1
        Next
    Wend
End Function

' end of coreutils_wc_neon_scalar.bi
