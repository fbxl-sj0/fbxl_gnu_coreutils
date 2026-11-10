/'
    Project: GNU Coreutils FreeBASIC port
    File: tac-pipe-api-index.bas

    Purpose:

        Give C2FB the external function signatures needed to translate the
        extra-distribution tac-pipe source in its obstack header context.

    Responsibilities:

        - Describe the replacement obstack calls and full_read ABI.
        - Describe the fixed three-argument error call used by tac-pipe.

    This file intentionally does NOT contain:

        - Function bodies or allocator state.
        - A declaration for the variadic error API used by other C sources.
'/

Declare Function C2fbTacPipeObstackBegin CDecl Alias "rpl_obstack_begin" _
    (ByVal obstack As Any Ptr, ByVal chunkSize As c2fb_c_int, _
     ByVal alignment As c2fb_c_int, ByVal allocateChunk As Any Ptr, _
     ByVal freeChunk As Any Ptr) As c2fb_c_int

Declare Sub C2fbTacPipeObstackNewChunk CDecl Alias "rpl_obstack_newchunk" _
    (ByVal obstack As Any Ptr, ByVal length As c2fb_size_t)

Declare Sub C2fbTacPipeObstackFree CDecl Alias "rpl_obstack_free" _
    (ByVal obstack As Any Ptr, ByVal object As Any Ptr)

Declare Function C2fbTacPipeFullRead CDecl Alias "full_read" _
    (ByVal fd As c2fb_c_int, ByVal buffer As Any Ptr, _
     ByVal count As c2fb_size_t) As c2fb_c_long

' tac-pipe passes exactly three arguments to error; the C ABI permits this
' fixed call declaration for this translation profile.
Declare Sub C2fbTacPipeError CDecl Alias "error" _
    (ByVal status As c2fb_c_int, ByVal errorNumber As c2fb_c_int, _
     ByVal format As Const ZString Ptr)

/' end of tac-pipe-api-index.bas '/
