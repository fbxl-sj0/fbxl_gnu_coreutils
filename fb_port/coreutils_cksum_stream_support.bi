' Project: GNU Coreutils FreeBASIC port
' File: coreutils_cksum_stream_support.bi
' Purpose: Provide the scalar POSIX cksum stream calculation used by the
'          FreeBASIC implementations of the optimized C helper entrypoints.
' Responsibilities: Read bounded stdio blocks, update the CRC table state,
'                   and report the byte count with the C helper's error rules.
' Does not contain CPU dispatch or command-line formatting.

Declare Function C2fbCksumFreadUnlocked CDecl Alias "fread_unlocked" (ByVal buffer As Any Ptr, ByVal elementSize As c2fb_size_t, ByVal elementCount As c2fb_size_t, ByVal inputFile As c2fb__IO_FILE Ptr) As c2fb_size_t
Declare Function C2fbCksumFerrorUnlocked CDecl Alias "ferror_unlocked" (ByVal inputFile As c2fb__IO_FILE Ptr) As c2fb_c_int
Declare Function C2fbCksumErrnoLocation CDecl Alias "__errno_location" () As c2fb_c_int Ptr
Extern C2fbCksumCrcTable(0 To 2047) Alias "crctab" As Const c2fb_c_ulong

Private Function C2fbCoreutilsCksumStreamScalar(ByVal inputFile As c2fb__IO_FILE Ptr, ByVal crcOutput As c2fb_c_ulong Ptr, ByVal lengthOutput As c2fb_c_long Ptr) As Byte
    Dim buffer(0 To 65535) As UByte
    Dim crc As c2fb_c_uint = 0
    Dim totalLength As c2fb_c_long = 0
    Dim bytesRead As c2fb_size_t
    Dim byteIndex As c2fb_size_t
    Dim tableIndex As c2fb_c_int
    Dim errnoAddress As c2fb_c_int Ptr

    If inputFile = 0 OrElse crcOutput = 0 OrElse lengthOutput = 0 Then Return 0

    While True
        ' Match the C helpers' 64 KiB stream read size.
        bytesRead = C2fbCksumFreadUnlocked(@buffer(0), 1, 65536, inputFile)
        If bytesRead = 0 Then Exit While

        If Cast(c2fb_uint64, bytesRead) > Cast(c2fb_uint64, &H7fffffffffffffff) - Cast(c2fb_uint64, totalLength) Then
            ' EOVERFLOW on the Linux x86-64 target.
            errnoAddress = C2fbCksumErrnoLocation()
            If errnoAddress <> 0 Then *errnoAddress = 75
            Return 0
        End If

        totalLength += Cast(c2fb_c_long, bytesRead)
        For byteIndex = 0 To bytesRead - 1
            tableIndex = Cast(c2fb_c_int, ((crc Shr 24) Xor Cast(c2fb_c_uint, buffer(byteIndex))) And &HFF)
            crc = Cast(c2fb_c_uint, ((crc Shl 8) Xor C2fbCksumCrcTable(tableIndex)))
        Next
    Wend

    If C2fbCksumFerrorUnlocked(inputFile) <> 0 Then Return 0

    *crcOutput = Cast(c2fb_c_ulong, crc)
    *lengthOutput = totalLength
    Return 1
End Function

' end of coreutils_cksum_stream_support.bi
