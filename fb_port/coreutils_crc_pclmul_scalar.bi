' Project: GNU Coreutils FreeBASIC port
' File: coreutils_crc_pclmul_scalar.bi
' Purpose: Implement the lib/crc PCLMUL entrypoint with the same scalar CRC.
' Responsibilities: Update an un-xored reflected CRC-32 state over input bytes.
' Does not contain runtime CPU detection or cksum command handling.

Function crc32_update_no_xor_pclmul CDecl Alias "crc32_update_no_xor_pclmul" (ByVal crc As c2fb_c_uint, ByVal buffer As Const Any Ptr, ByVal length As c2fb_size_t) As c2fb_c_uint
    Dim inputBytes As Const UByte Ptr = CPtr(Const UByte Ptr, buffer)
    Dim byteIndex As c2fb_size_t
    Dim bitIndex As c2fb_c_int

    ' Reflected CRC-32 polynomial used by lib/crc.c.
    If length = 0 Then Return crc

    For byteIndex = 0 To length - 1
        crc = crc Xor inputBytes[byteIndex]
        For bitIndex = 0 To 7
            If (crc And 1) <> 0 Then
                crc = (crc Shr 1) Xor &HEDB88320
            Else
                crc = crc Shr 1
            End If
        Next
    Next

    Return crc
End Function

' end of coreutils_crc_pclmul_scalar.bi
