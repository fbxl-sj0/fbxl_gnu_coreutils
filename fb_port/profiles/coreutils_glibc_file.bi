/'
    Project: GNU Coreutils FreeBASIC port

    File: coreutils_glibc_file.bi

    Purpose:

        Describe the configured glibc FILE storage record for C2FB bodies
        that inspect stream internals.

    Responsibilities:

        - Match glibc's _IO_FILE size and member offsets on Linux x86-64.
        - Expose the fields used by freadahead and fseterr.

    This file intentionally does NOT contain:

        - A portable FILE implementation.
        - Stream operations, buffering policy, or ownership rules.

    These fields are private glibc ABI details. Recheck the layout against
    the system C header before changing the target libc or ABI.
'/

#ifndef __COREUTILS_GLIBC_FILE_BI__
#define __COREUTILS_GLIBC_FILE_BI__

Type CoreutilsGlibcFile
    _flags As Long
    _IO_read_ptr As Any Ptr
    _IO_read_end As Any Ptr
    _IO_read_base As Any Ptr
    _IO_write_base As Any Ptr
    _IO_write_ptr As Any Ptr
    _IO_write_end As Any Ptr
    _IO_buf_base As Any Ptr
    _IO_buf_end As Any Ptr
    _IO_save_base As Any Ptr
    _IO_backup_base As Any Ptr
    _IO_save_end As Any Ptr
    _markers As Any Ptr
    _chain As Any Ptr
    _fileno As Long
    _flags2(0 To 2) As UByte
    _short_backupbuf As UByte
    _old_offset As CLong
    _cur_column As UShort
    _vtable_offset As Byte
    _shortbuf As Byte
    _lock As Any Ptr
    _offset As CLong
    _codecvt As Any Ptr
    _wide_data As Any Ptr
    _freeres_list As Any Ptr
    _freeres_buf As Any Ptr
    _prevchain As Any Ptr Ptr
    _mode As Long
    _unused3 As Long
    _total_written As ULongInt
    _unused2(0 To 7) As Byte
End Type

#endif

/' end of coreutils_glibc_file.bi '/
