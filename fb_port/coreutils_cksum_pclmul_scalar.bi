' Project: GNU Coreutils FreeBASIC port
' File: coreutils_cksum_pclmul_scalar.bi
' Purpose: Keep the PCLMUL cksum entrypoint available without SIMD code.
' Responsibilities: Route the entrypoint to the shared scalar stream routine.
' Does not contain CPU feature detection or checksum formatting.

#include once "fb_port/coreutils_cksum_stream_support.bi"

Function cksum_pclmul CDecl Alias "cksum_pclmul" (ByVal inputFile As c2fb__IO_FILE Ptr, ByVal crcOutput As c2fb_c_ulong Ptr, ByVal lengthOutput As c2fb_c_long Ptr) As Byte
    Return C2fbCoreutilsCksumStreamScalar(inputFile, crcOutput, lengthOutput)
End Function

' end of coreutils_cksum_pclmul_scalar.bi
