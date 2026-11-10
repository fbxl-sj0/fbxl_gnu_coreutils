' Project: GNU Coreutils FreeBASIC port
' File: coreutils_cksum_vmull_scalar.bi
' Purpose: Keep the ARM VMULL cksum entrypoint available with scalar code.
' Responsibilities: Preserve the C stream-helper ABI and reuse the shared
'                   POSIX CRC calculation.
' Does not contain ARM vector operations or CPU feature detection.

#include once "fb_port/coreutils_cksum_stream_support.bi"

Function cksum_vmull CDecl Alias "cksum_vmull" (ByVal inputFile As c2fb__IO_FILE Ptr, ByVal crcOutput As c2fb_c_ulong Ptr, ByVal lengthOutput As c2fb_c_long Ptr) As Byte
    Return C2fbCoreutilsCksumStreamScalar(inputFile, crcOutput, lengthOutput)
End Function

' end of coreutils_cksum_vmull_scalar.bi
