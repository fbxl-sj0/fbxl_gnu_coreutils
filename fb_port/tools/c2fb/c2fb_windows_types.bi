/'
    Project: C2FB Windows ABI type policy
    -------------------------------------

    File: c2fb_windows_types.bi

    Purpose:

        Map common Windows SDK scalar and pointer typedefs during SQLite
        engine-body conversion.

    Responsibilities:

        - Restrict Windows typedef aliases to os_win.c and mutex_w32.c inputs.
        - Preserve the fixed widths used by Win32 and Win64 ABI declarations.
        - Map common string, handle, and pointer typedefs to FreeBASIC pointer types.

    This file intentionally does NOT contain:

        - Windows record layout definitions or API calling-convention policy.
        - Cygwin, Windows CE, or other non-desktop Windows typedef variants.
'/

Private Function C2fbIsWindowsEngineSource( _
    ByRef translation As C2fbTranslationContext _
) As Long
    Dim sourcePath As String = LCase( _
        translation.sourceUnit.diagnosticState.currentSourceLocation.path)
    If Right(sourcePath, Len("os_win.c")) = "os_win.c" OrElse _
       Right(sourcePath, Len("mutex_w32.c")) = "mutex_w32.c" Then Return -1
    Return 0
End Function

Private Function ResolveC2fbWindowsAbiType( _
    ByVal sourceType As String, ByRef pointerCount As Long, _
    ByRef isConst As Long, ByRef baseType As String _
) As Long
    baseType = ""
    Select Case sourceType
    Case "BOOL", "LONG", "HRESULT", "NTSTATUS"
        baseType = "Long"
    Case "DWORD", "ULONG", "UINT"
        baseType = "ULong"
    Case "WORD", "WCHAR", "USHORT"
        baseType = "UShort"
    Case "BYTE", "UCHAR", "BOOLEAN"
        baseType = "UByte"
    Case "LONGLONG", "LONG64", "INT64"
        baseType = "c2fb_int64"
    Case "ULONGLONG", "DWORD64", "UINT64"
        baseType = "c2fb_uint64"
    Case "LARGE_INTEGER", "ULARGE_INTEGER"
        Return 0
    Case "SIZE_T", "ULONG_PTR", "DWORD_PTR", "UINT_PTR", "WPARAM"
        baseType = "c2fb_size_t"
    Case "LONG_PTR", "LPARAM", "LRESULT"
        baseType = "c2fb_int64"
    Case "LPCSTR", "PCSTR", "LPCCH", "PCCH"
        baseType = "ZString"
        pointerCount += 1
        isConst = -1
    Case "LPSTR", "PSTR", "LPCH", "PCH"
        baseType = "ZString"
        pointerCount += 1
    Case "LPCWSTR", "PCWSTR", "LPCWCH", "PCWCH"
        baseType = "UShort"
        pointerCount += 1
        isConst = -1
    Case "LPWSTR", "PWSTR", "LPWCH", "PWCH"
        baseType = "UShort"
        pointerCount += 1
    Case "PDWORD", "LPDWORD", "PULONG", "LPULONG", "PUINT", "LPUINT"
        baseType = "ULong"
        pointerCount += 1
    Case "PBOOL", "LPBOOL", "PLONG", "LPLONG", "PINT", "LPINT"
        baseType = "Long"
        pointerCount += 1
    Case "PWORD", "LPWORD", "PUSHORT", "LPUSHORT"
        baseType = "UShort"
        pointerCount += 1
    Case "PBYTE", "LPBYTE", "PUCHAR", "LPUCHAR", "PBOOLEAN", "LPBOOLEAN"
        baseType = "UByte"
        pointerCount += 1
    Case "LPCVOID"
        baseType = "Any"
        pointerCount += 1
        isConst = -1
    Case "PVOID", "LPVOID", "HANDLE", "HWND", "HINSTANCE", "HMODULE", _
         "HKEY", "HDC", "HGLOBAL", "HLOCAL", "HRSRC", "HMONITOR", _
         "HGDIOBJ", "HFONT", "HBITMAP", "HBRUSH", "HMENU", "HICON", _
         "FARPROC", "PROC", "LPSECURITY_ATTRIBUTES", "PSECURITY_ATTRIBUTES", _
         "LPOVERLAPPED", "POVERLAPPED", "LPCRITICAL_SECTION", _
         "PCRITICAL_SECTION", "PSRWLOCK", "LPTHREAD_START_ROUTINE", _
         "PTHREAD_START_ROUTINE"
        baseType = "Any"
        pointerCount += 1
    Case Else
        Return 0
    End Select
    Return -1
End Function

/' end of c2fb_windows_types.bi '/
