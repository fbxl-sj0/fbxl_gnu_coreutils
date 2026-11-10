/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_limits.bi

    Purpose:

        Define the bounded resource limits shared by the C2FB pipeline.

    Responsibilities:

        - Bound token, declaration, source-file, and symbol collections.
        - Bound body-local storage and generated array dimensions.
        - Bound compiler argument expansion and response-file nesting.

    This file intentionally does NOT contain:

        - Translation models or command dispatch identifiers.
        - Input parsing, allocation, or limit-reporting behavior.
'/

Private Const MAX_TYPE_WORDS As Long = 256
' Whole C declarations may contain large initializers; this is separate from
' the smaller type-token workspace used while resolving their declarators.
' Macro-expanded 256-entry encoding tables can exceed 200,000 tokens.
Private Const MAX_C_DECLARATION_TOKENS As Long = 262144
Private Const MAX_FUNCTIONS As Long = 8192
' Hash constants for bounded FreeBASIC project name indexes.
' FNV-1a 32-bit constants plus an avalanche finalizer. Hash products are
' masked to 32 bits while held in ULongInt, so intermediate multiplication
' cannot overflow before the mask is applied.
Private Const C2FB_NAME_HASH_SEED As ULongInt = &h811C9DC5ULL
Private Const C2FB_NAME_HASH_MULTIPLIER As ULongInt = &h01000193ULL
Private Const C2FB_NAME_HASH_MASK As ULongInt = &hFFFFFFFFULL
Private Const C2FB_NAME_HASH_FINAL_MULTIPLIER_1 As ULongInt = &h85EBCA6BULL
Private Const C2FB_NAME_HASH_FINAL_MULTIPLIER_2 As ULongInt = &hC2B2AE35ULL
' Generated body diagnostic comments stay bounded and on one source line.
Private Const MAX_C2FB_BODY_DIAGNOSTIC_COMMENT_LENGTH As Long = 512
' Start body candidate storage small and grow it as source functions are found.
Private Const INITIAL_BODY_CANDIDATE_CAPACITY As Long = 128
' FreeBASIC stores pointer depth in FB_DATATYPE_PTRMASK with eight levels.
' Source: FreeBASIC compiler symbol definitions (FB_DT_PTRLEVELS).
Private Const MAX_FREEBASIC_POINTER_LEVELS As Long = 8
' Platform SDK headers can contribute many declarations that are not functions
' in the selected source file, so declaration storage has its own larger bound.
Private Const MAX_DECLARATIONS As Long = 32768
' Project-wide FreeBASIC layouts and generated source records accumulate from
' many input files. Allow eight declaration-sized blocks here; the smaller
' per-unit record workspace remains capped by MAX_FUNCTIONS.
Private Const MAX_C2FB_BODY_CATALOG_FIELDS As Long = MAX_DECLARATIONS * 8
' C records, aliases, and callback signatures are collected per source unit;
' they follow declaration storage rather than the per-function workspace cap.
Private Const MAX_C2FB_BODY_RECORD_BINDINGS As Long = MAX_DECLARATIONS
Private Const MAX_C2FB_BODY_RECORD_FIELDS As Long = MAX_C2FB_BODY_CATALOG_FIELDS
Private Const MAX_C2FB_STRING_INDEX_MAP_CAPACITY As Long = _
    MAX_C2FB_BODY_RECORD_FIELDS * 2
Private Const MAX_C2FB_BODY_TYPE_ALIASES As Long = MAX_DECLARATIONS
Private Const MAX_C2FB_BODY_CALLBACK_TYPES As Long = MAX_DECLARATIONS
' One C record declaration cannot exceed its token workspace.
Private Const MAX_C2FB_DECLARATION_RECORD_FIELDS As Long = _
    MAX_C_DECLARATION_TOKENS
' Header symbols include declarations plus a separate macro name workspace.
Private Const MAX_C2FB_SYMBOLS As Long = MAX_DECLARATIONS + MAX_FUNCTIONS
Private Const MAX_GENERIC_HEADER_OUTPUT_NAMES As Long = MAX_C2FB_SYMBOLS
' One SDK enum can contain more members than a typical C local declaration list.
Private Const MAX_GENERIC_ENUM_MEMBERS As Long = MAX_GENERIC_HEADER_OUTPUT_NAMES
Private Const MAX_GENERIC_HEADER_MACROS As Long = MAX_C2FB_SYMBOLS
' Occurrence events combine declarations, inline function bodies, and macro definitions.
Private Const MAX_GENERIC_HEADER_OCCURRENCES As Long = _
    MAX_DECLARATIONS + MAX_GENERIC_HEADER_OUTPUT_NAMES + MAX_GENERIC_HEADER_MACROS
' Body globals come from the same collected top-level declaration set.
Private Const MAX_BODY_EXTERNAL_OBJECTS As Long = MAX_DECLARATIONS
Private Const MAX_GENERIC_COMPILER_ARGUMENTS As Long = MAX_FUNCTIONS * 2
Private Const MAX_SIMPLE_VARIABLES As Long = 512
' Automatic body-local array paths are capped to keep generated candidates bounded.
' Keep compiler-emitted inline local arrays bounded; larger valid local arrays
' use FreeBASIC's managed dynamic-array storage.
' Small automatic local arrays use fixed storage; larger supported local arrays
' use FreeBASIC's managed dynamic-array path.
Private Const MAX_SIMPLE_ARRAY_COUNT As Long = 65535
' Bound the synthetic record used to initialize array-first unions. One and
' two elements cover the configured SNaN bit patterns without expanding every
' included header's larger byte-storage unions.
Private Const MAX_C2FB_UNION_ARRAY_INITIALIZER_ELEMENTS As Long = 2
' Bound the temporary element table used to flatten managed local initializers.
Private Const MAX_DYNAMIC_ARRAY_INITIALIZER_COUNT As Long = 262144
' Permit large zero-initialized static I/O buffers without expanding elements.
Private Const MAX_STATIC_LOCAL_ARRAY_COUNT As Long = 524288
' Static C tables need more initializer elements than a body-local declaration.
Private Const MAX_GENERIC_STATIC_INITIALIZER_VALUES As Long = 65535
' Bound decoded C string literals before expanding them into static array values.
Private Const MAX_C_STRING_LITERAL_BYTES As Long = 65535
' Bound exact compile-time hexadecimal-float conversion work and output size.
Private Const MAX_GENERIC_HEX_FLOAT_SIGNIFICAND_DIGITS As Long = 256
Private Const MAX_GENERIC_HEX_FLOAT_DECIMAL_DIGITS As Long = 4096
Private Const MAX_GENERIC_HEX_FLOAT_EXPONENT As Long = 8192
' FreeBASIC caps each static array dimension at signed 32-bit element count.
Private Const MAX_GENERIC_ARRAY_COUNT As Long = 2147483647
Private Const MAX_GENERIC_ARRAY_BOUND_VALUE As LongInt = 2147483647LL
Private Const MAX_GENERIC_ARRAY_BOUND_MAGNITUDE As ULongInt = 2147483647ULL
Private Const MAX_GENERIC_ARRAY_RANK As Long = 16
' Bound recursive response-file expansion and prevent argument-file cycles from looping.
Private Const MAX_GENERIC_RESPONSE_DEPTH As Long = 16
' Reserve the low-order part of occurrence keys for offsets within one source line.
Private Const C2FB_SOURCE_ORDER_LINE_SCALE As LongInt = 1000000000LL
' Expansion probes are optional; cap compiler output before reading it into memory.
Private Const MAX_GENERIC_MACRO_EXPANSION_BYTES As LongInt = 4194304LL
Private Const MAX_GENERIC_MACRO_EXPANSION_OUTPUT_BYTES As LongInt = 268435456LL
Private Const MAX_GENERIC_MACRO_EXPANSION_DEPTH As Long = 64
' Attribution files are copied into generated comments, so bound their input.
Private Const MAX_GENERIC_TITLE_FILE_BYTES As LongInt = 1048576LL

/' end of c2fb_limits.bi '/
