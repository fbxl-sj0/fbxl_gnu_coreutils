/*
    Project: SQLite FreeBASIC port tools

    File: rejected.c

    Purpose:

        Describe expression forms that still require manual porting.

    Responsibilities:

        - Keep unsupported storage, strings, and type assumptions visible.
        - Verify that a failed expression rejects its complete function body.

    This file intentionally does NOT contain:

        - Code intended for the FreeBASIC port or the compiled C reference.
*/

typedef struct Item Item;
struct Item { int value; unsigned int flag:1; };
int sqlite3AbsInt32(int);

int c2fbRejectIncrement(int a){ return (a + 1)++; }
int c2fbRejectMultiline(int a){
    return a +
        (a + 1)++;
}
int c2fbRejectComma(int a, int b){ return (a, unknown); }
int c2fbRejectAssignment(int a){ return (a + 1) = 2; }
int c2fbRejectUnknownFunctionPointer(void *a, int b){ return a(b); }
int c2fbRejectMultiCharacter(void){ return 'ab'; }
int c2fbRejectHighCharacter(void){ return '\x80'; }
int c2fbRejectString(void){ return sqlite3AbsInt32("text"); }
int c2fbRejectUnknownCast(int a){ return (Mystery)a; }
int c2fbRejectUnknownDivision(Item *a){ return a->value / 2; }
int c2fbRejectOpaqueMember(void *a){ return a->value; }
int c2fbRejectInvalidOctal(void){ return 09; }
int c2fbRejectInvalidSuffix(void){ return 1UU; }
int c2fbRejectOverflowLiteral(void){ return 18446744073709551616ULL; }
int c2fbRejectOverflowDecimal(void){ return 9223372036854775808; }
int c2fbRejectBrokenGroup(int a){ return (a + 1; }
int c2fbRejectFloatSuffix(void){ return 1.0ff; }
int c2fbRejectStringEscape(void){ return "\x100"[0]; }
int c2fbRejectAggregateSize(Item *a){ return sizeof(*a); }
int c2fbRejectDiscardedSideEffect(int a){ const int count = a; (void)(count++); return count; }
int c2fbRejectBreak(void){ break; return 0; }
int c2fbRejectContinue(void){ continue; return 0; }
int c2fbRejectUndefinedGoto(void){ goto missing; return 0; }
int c2fbRejectDuplicateLabel(void){ x: x: return 0; }
int c2fbRejectOutOfRangeArray(void){ int items[2147483648ULL]; return sizeof(items); }
int c2fbRejectArrayInitializer(void){ int items[2] = {1,2,3}; return items[0]; }
int c2fbRejectCallbackArity(int (*a)(int), int b){ return a(b,b); }
int c2fbRejectBitfieldAssignment(Item *a){ return a->flag = 2; }
int c2fbRejectBitfieldIncrement(Item *a){ return a->flag++; }
int c2fbRejectConstWrite(const int *a){ return ++*a; }

/* end of rejected.c */
