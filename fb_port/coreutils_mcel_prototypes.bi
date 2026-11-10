/'
    Project: GNU Coreutils FreeBASIC port
    --------------------------------------

    File: coreutils_mcel_prototypes.bi

    Purpose:

        Declare the shared C ABI for the multibyte helpers provided by mcel.c.

    Responsibilities:

        - Let translated consumers call the shared mcel helper object.
        - Use the source-context mcel_t record and C ABI scalar aliases.

    This file intentionally does NOT contain:

        - Multibyte decoding implementations.
        - Per-source inline helper bodies.
'/

Declare Function mcel_ch CDecl Alias "mcel_ch" _
    (ByVal ch As c2fb_c_uint, ByVal length As c2fb_size_t) As c2fb_mcel_t
Declare Function mcel_err CDecl Alias "mcel_err" _
    (ByVal errorByte As UByte) As c2fb_mcel_t
Declare Function mcel_isbasic CDecl Alias "mcel_isbasic" _
    (ByVal character As Byte) As Byte
Declare Function mcel_scan CDecl Alias "mcel_scan" _
    (ByVal text As Const ZString Ptr, ByVal limit As Const ZString Ptr) _
    As c2fb_mcel_t
Declare Function mcel_scant CDecl Alias "mcel_scant" _
    (ByVal text As Const ZString Ptr, ByVal terminator As Byte) As c2fb_mcel_t
Declare Function mcel_scanz CDecl Alias "mcel_scanz" _
    (ByVal text As Const ZString Ptr) As c2fb_mcel_t

/' end of coreutils_mcel_prototypes.bi '/
