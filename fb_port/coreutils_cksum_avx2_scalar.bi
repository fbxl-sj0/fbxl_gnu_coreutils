' Project: GNU Coreutils FreeBASIC port
' File: coreutils_cksum_avx2_scalar.bi
' Purpose: Keep the AVX2 cksum entrypoint available without a C vector ABI.
' Responsibilities: Route the entrypoint to the shared scalar stream routine.
' Does not contain CPU feature detection or checksum formatting.

#include once "fb_port/coreutils_cksum_stream_support.bi"

Function cksum_avx2 CDecl Alias "cksum_avx2" (ByVal inputFile As c2fb__IO_FILE Ptr, ByVal crcOutput As c2fb_c_ulong Ptr, ByVal lengthOutput As c2fb_c_long Ptr) As Byte
    Return C2fbCoreutilsCksumStreamScalar(inputFile, crcOutput, lengthOutput)
End Function

' end of coreutils_cksum_avx2_scalar.bi
