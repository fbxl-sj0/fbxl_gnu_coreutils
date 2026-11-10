/*
    Project: SQLite FreeBASIC port tools

    File: support.c

    Purpose:

        Supply the same external call target to C and generated FreeBASIC tests.

    Responsibilities:

        - Implement sqlite3AbsInt32 for the bounded test inputs.

    This file intentionally does NOT contain:

        - SQLite engine code or a substitute for testing the full port.
*/

int sqlite3AbsInt32(int value){
  return value < 0 ? -value : value;
}

/* end of support.c */
