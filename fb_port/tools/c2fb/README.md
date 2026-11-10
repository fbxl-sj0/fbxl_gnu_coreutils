# c2fb

## Standalone checkout

Install FreeBASIC, a C compiler, GNU Make, Python 3, and Tcl, then build from
this repository's root:

```sh
make all
```

This produces `build/c2fb` and the SQLite API-table helper
`build/api_routines`. Building the translator does not require a SQLite
checkout.

The regression suite includes SQLite-specific conversions and uses the
companion [FreeBASIC SQLite repository](https://github.com/fbxl-sj0/freebasic-sqlite).
Clone it beside this checkout and run:

```sh
git clone https://github.com/fbxl-sj0/freebasic-sqlite.git ../freebasic-sqlite
cd ../freebasic-sqlite
./configure --dev
make sqlite3.h parse.h opcodes.h
cd ../c2fb
make test
```

The Makefile test target defaults to the SQLite checkout two directories above
this integrated `fb_tools/c2fb` directory. For a separate checkout, use
`make test SQLITE_SOURCE_DIR=/path/to/freebasic-sqlite`. Set
`FBC_SOURCE_DIR=/path/to/fbc/src` to enable the optional compiler-source
probes. The Python test runner accepts these locations through
`--sqlite-source-directory` and `--fbc-source-directory`. Candidate
compilation checks use `FB_SOURCE_DIR`, which defaults to the selected
checkout's `fb_src` directory.

The detailed examples below retain paths from the original SQLite workspace.
In this standalone checkout, use `build/c2fb` for
`fb_tools/c2fb/build/c2fb` and run Python helpers directly from this directory.
SQLite inputs and port sources come from the companion checkout.

## Converter

`c2fb` combines a SQLite-focused bulk converter with a generic C header
declaration path. Its default mode reads SQLite C headers and emits FreeBASIC
`Declare` statements for common SQLite ABI types. Its `defines` mode extracts
numeric `SQLITE_*` constants and translates simple integer expressions. Its
`fp-tables` mode extracts SQLite's fixed-width power-of-ten tables from
`src/util.c`. Its `translate-simple` modes convert a conservative subset of C
function bodies into reviewable FreeBASIC candidates.

C2FB is distributed under the GNU General Public License, version 3 or any
later version (GPL-3.0-or-later). See [LICENSE](LICENSE).

The ongoing move toward a shared front-end, per-input translation context, and
separate output backends is described in [ARCHITECTURE.md](ARCHITECTURE.md).

Build just the C2FB executable, without the SQLite-only API-table helper, with
`make converter`. The executable includes the generic `generic-header` mode and
the SQLite-specific modes, including `api-routines`. `make all` also builds the
standalone `api_routines` frontend, which calls the same adapter.

`generic-header` preprocesses a C header for one target configuration and emits
declarations for supported functions and external objects. It preprocesses
declarations, macro-origin locations, and active include directives with
`cc -E -dD -dI -x c`, retaining preprocessor line markers so diagnostics can
report source paths and include mappings can identify the defining header. It
collects the selected active macro table with `cc -E -dM -x c`. Pass a compiler and
preprocessor options to select include paths, defines, or another target.
Pass `-v -v` to print elapsed times for declaration collection, record planning,
layout analysis, and output emission. Single `-v` keeps the shorter command
summary.
Repeat `--c-include=Header.h` to force
related C headers into the same preprocessing pass before the primary header;
their declarations and macro state are collected into one output. Repeat
`--type-map=CName=FbType` to map
plain C typedef names or built-in C types to FreeBASIC type names available
before the generated file. For example, `--type-map=char=Byte` emits `Byte Ptr`
for `char *` instead of `ZString Ptr`. Mapped pointer types retain their C
pointer depth. In `generic-header`, follow a matching type map with
`--type-alignment=CName=Bytes` when an external FreeBASIC carrier's ABI
alignment cannot be inferred from the C declaration. The value must be one of
1, 2, 4, 8, or 16 bytes; C2FB uses it when calculating containing and nested
record layouts. Repeat `--typedef-hint=CName` (or `-typedefhint CName`) when a
C identifier is used as a typedef in an expression cast but its declaration is
not visible to C2FB. The hint treats the same-named FreeBASIC type as the C
type; use `--type-map` when its FreeBASIC name differs. A hint does not create
or define that type, and an explicit type map takes precedence regardless of
option order. The option is available in generic-header and generic-body modes.
Use `--typedef-hint` when an expression macro casts to a C typedef that is not
declared in the preprocessed input; such casts remain macros until use, so the
matching FreeBASIC type can come from `--fb-include` without C2FB guessing its
ABI width. When the typedef is present in the C header, C2FB uses the emitted
FreeBASIC alias in the cast.
Repeat `--expand-type=CName` to omit a supported typedef's
FreeBASIC alias and map uses to its resolved type; `-expand CName` is accepted
as an fbfrog command-line compatibility spelling. Scalar and pointer typedefs
and aliases to tagged records can be expanded this way. Fixed array typedefs
are expanded at use sites, including their individual dimensions. Callback
typedefs, anonymous record typedefs, and names that do not match a supported
typedef remain as aliases; generated files report whether each requested
expansion matched.
Repeat `--expand-macro=Pattern` to expand the replacement list of matching
definitions through the selected C preprocessor. Use
`--expand-in-define=Pattern` to expand calls to matching macros inside other
replacement lists; calls that use a containing function macro's parameters
remain intact to avoid changing their meaning. The fbfrog spelling
`-expandindefine Pattern` maps to this call-site mode. Direct macro-definition
expansion supports object-like, fixed-parameter, and safely reconstituted
variadic macros. Expansions involving `__VA_OPT__`, dynamic builtins, or
stringizing and token-pasting that consume parameters remain unchanged and are
reported as unsupported. Generated files also report unmatched requests.
`--no-expand-macro=Pattern` or `-noexpand Pattern` excludes matching names from
a broader expansion pattern; C2FB does not expand macro definitions by default.
If the preprocessor's `-dD` stream ends with `#undef NAME` while its `-dM`
table still reports `NAME` as active, C2FB automatically re-expands that macro
in the original header context. This reconciles macro state restored by
`_Pragma("pop_macro")`; the generated header reports the number of recovered,
unsupported, or explicitly excluded names.
Repeat `--forward-decl=Pattern` to retain selected incomplete `struct` or
`union` tags as FreeBASIC forward type aliases; `-addforwarddecl Name` is the
fbfrog spelling. A pattern may match either the tag or a typedef name for that
tag. C2FB reuses a complete emitted record when available and
otherwise emits a forward alias, including when a record layout was filtered
out. An explicit C `extern` object with an incomplete record type can be
declared and addressed; FBC rejects operations that read, copy, or index the
object before its layout is complete. Other uses that require the incomplete
type by value remain skipped.
For separately generated declarations and record layouts, use the same prefix
and type renames so both files name the same backing type.
Repeat `--rename=CName=FbName` to change a generated FreeBASIC
identifier. `--prefix=FbPrefix` changes the default `c2fb_` prefix used for
generated identifiers; explicit `--rename` mappings take precedence. Function
and object declarations retain their C symbol through
`Alias`; renames can target functions, objects, types, enum constants, and
macros. Use `--rename-tag=CName=FbName` and
`--rename-typedef=CName=FbName` to rename C's separate tag and ordinary
identifier namespaces independently when a tag and typedef share a spelling.
If the resulting FreeBASIC identifier is a reserved word, C2FB appends `_` so
the binding remains compilable; C procedure and object `Alias` names stay tied
to their original C symbols.
Record members use FreeBASIC's narrower field rules: C fields such as `new`
and `and` are emitted as `new_` and `and_`, while accepted field names such as
`type` remain unchanged. If that suffix conflicts with another C field, C2FB
adds underscores until the FreeBASIC member is unique, and translated bodies
keep each access tied to its original C field.
The namespace-specific mapping takes precedence over a general `--rename` for
that type namespace. Use `--rename-proc` to rename procedures without changing
objects or macros. `--rename-proc-prefix=Prefix` prepends a FreeBASIC identifier
prefix to procedure names in generic-header and generic-body modes; explicit
`--rename-proc` and general `--rename` mappings take precedence. C linker names
remain unchanged through `Alias`. This is useful when converted procedures
share names with host runtime functions. C2FB reports whether the prefix matched
a procedure. Use `--rename-define` to rename C macros, and
`--rename-macro-param` to rename formal parameters within function-like
macros. Macro parameter mappings change only formal names and their uses in
that macro, not unrelated C identifiers with the same spelling. C2FB adds a
matched/unused rename list at the end of the
generated file, following fbfrog's rename audit comment. The fbfrog spelling
`-rename_ Name` renames that identifier to `Name_`. Repeat `--exclude=Pattern`
to omit top-level functions, external objects, and macros by C name;
`--exclude-proc`, `--exclude-variable`, and `--exclude-define` limit the pattern
to one declaration namespace. `*` matches zero or more characters and `?`
matches one. Quote wildcard patterns in the shell. `-remove1st Pattern` removes the first
matching top-level function declaration or macro definition in preprocessor
order. `-remove2nd Pattern` keeps the first such occurrence and removes later
ones; `--remove-first` and `--remove-repeated` are the long-form spellings.
`--include-static-objects` lets file-scope `static` objects through symbol
exclusion patterns. `--private-static-objects` gives those declarations
module-private FreeBASIC storage, which is useful when generating one context
per C translation unit. File-scope C thread-local objects (`_Thread_local` or
`__thread`) and private C++ `thread_local` objects become FreeBASIC `Thread
Local` declarations. External C++ thread-local objects remain unsupported
because C2FB does not resolve their C++ linker names.
Occurrence removal covers functions, object and typedef declarators, record
names, enum members, and macro definitions. Record fields and macro parameters
are not separate top-level occurrences.
Compiler predefined macros, including definitions from GCC's injected
`stdc-predef.h`, remain private by default. Definitions from the requested
headers are emitted normally, including double-underscore names. Repeat
`--emit-reserved-defines=Pattern` to export selected predefined macros; patterns
support `*` and `?`, and generated files report which requests matched.
`--remove-empty-reserved-defines` (or fbfrog's
`-removeEmptyReservedDefines`) omits
empty object-like macros named with `__` or `_[A-Z]` prefixes, following
fbfrog's corresponding option. Other empty object-like and function-like
macros remain as empty FreeBASIC macro definitions. Typedefs and record layouts stay available to
other declarations unless `--exclude-type=Pattern` matches the typedef name,
record tag, or record typedef alias. References to an excluded by-value type
still need that type from `--fb-include` or an earlier declaration.
Repeat `--emit-source=Pattern` to emit declarations, records, enums, macros, and
inline function macros originating in matching source paths. If any include
pattern is given, other source paths are omitted; repeat
`--exclude-source=Pattern` to omit paths even when they match an include
pattern. The earlier `--emit-declarations-from` and
`--exclude-declarations-from` spellings remain aliases. Patterns use `*` and
`?`, normalize slash direction, and match a suffix of the preprocessor source
path, so `SDL3/SDL_video.h` and `*/SDL3/*.h` work with absolute line markers.
All source files still participate in type indexing so imported types can be
resolved. Object-like integer, type, and string macros from omitted paths remain
available as private dependencies when their values can be lowered. Types
omitted by the filter must be available through `--fb-include`, a
`--preserve-include` mapping, or an earlier binding when emitted declarations
use them. Library pragmas follow the source
of their defining `#pragma`. The generated file reports which source patterns
matched.
For ordered output routing, repeat `--source-route Pattern Destination` and
set `--source-destination Destination`. Routes match the full normalized source
path, and the first matching route wins. The target-matrix adapter uses this to
preserve fbfrog's first-match behavior when multiple `-emit` patterns overlap.
For limited C++ declaration syntax, pass a C++ compiler and `-x c++` after the
generic-header output path, or use `--cxx`. Simple lvalue-reference parameters
and external scalar or pointer references lower to `ByRef`. Translatable
default arguments are retained for scalar expressions, null pointers, and
narrow or wide string literals; unsupported defaults cause the declaration to
be skipped. `--traditional-cpp-fallback` retries preprocessing with the
compiler's traditional mode after standard mode fails, for legacy headers whose
preprocessor expressions depend on those rules. It requires a GCC/Clang-compatible
preprocessor. This does not add C++ name mangling, classes, templates, or overload
support; linkable declarations still need C linkage or an external wrapper
with a C symbol.
Repeat `--move-above=Name=ReferenceName` to place one C declaration before
another; `-moveabove Name ReferenceName` is accepted for fbfrog command-line
compatibility. Names may be C identifiers, generated prefixed identifiers, or
explicit FreeBASIC names from `--rename`. C2FB reorders individual items in a
comma-separated declaration and declarations within the same output phase.
It also hoists simple scalar external objects and prototypes whose parameter
and return types use built-ins, including pointers to those types. Pointer-only
declarations of tagged records can move when `--forward-decl` requests the
matching tag. These safe moves can go before a simple built-in typedef; other
cross-phase moves remain unapplied when they could use a type before it is
available. Macro and inline-macro ordering remains dependency-driven.
Repeat `--ifndef-decl=Pattern` to wrap matching generated bindings in
`#ifndef`/`#endif`, and `--undef-before-decl=Pattern` to emit `#undef` before
them. The fbfrog spellings `-ifndefdecl` and `-undefbeforedecl` are accepted
with a following pattern argument. Patterns match the C name or generated FreeBASIC name
and support `*` and `?`. Record aliases and their backing layouts share the
guard selected for the record. When both options match, C2FB emits `#undef`
before the `#ifndef` guard. Generated files report which guard patterns matched.
Use `--undef=Macro` (or `--undef Macro` / `-undef Macro`) to emit a raw
FreeBASIC `#undef` after configured `--fb-include` files and before generated
declarations. This removes a macro introduced by an included binding; it is
separate from `--undef-before-decl`, which targets generated declaration names.
Decimal tokens are also accepted for fbfrog compatibility; FreeBASIC treats an
unmatched numeric `#undef` as a no-op.
`--string=Pattern` and `--no-string=Pattern` apply the same wildcards to C
parameter, field, typedef, or object names; record fields can
also use `Record.field`, and parameters can use `Function.parameter` or
`Function.index`, where the index is zero-based and works for unnamed
parameters. The function selector can also be a wildcard; callback typedefs
and named function-pointer parameters own their nested parameter indexes.
`Record` is the C tag or typedef name. The last matching option wins.
`--string` also maps fixed `char` and `unsigned char` arrays to `ZString * N`
storage, and unsized character arrays to a `ZString Ptr` accessor. For selected
`wchar_t` pointers and arrays, `--string` opts into `WString`; use it only when C `wchar_t` and
FreeBASIC `WString` have the same target width. Wide-character declarations
otherwise use the `wchar_t` alias from `crt/stddef.bi`. Check that alias against
the C target: FreeBASIC's compiler source notes that Android `WSTRING` is one
byte while C wide characters are four, so `--type-map=wchar_t=Long` can be
needed there. Run the C preprocessor with options for the same target as the
FreeBASIC compiler that will use the output. C built-ins map through FreeBASIC ABI
types: `long` becomes `CLong`, and `size_t` becomes `UInteger`. The generated
file includes `crt/stddef.bi`, `crt/long.bi`, and `crt/longdouble.bi`. An explicit
`--type-map=size_t=...` takes precedence for `c2fb_size_t`, so target profiles can
preserve the source ABI spelling, such as `CULong` for Linux x86-64.
By default, generic C2FB bindings keep fixed character arrays as byte storage.
`--fbfrog-string-defaults` opts into FBFrog's automatic `char`/`wchar_t`
typedef, pointer, and array treatment; the FBFrog script adapter enables this
mode. Wide strings are emitted only when the C `wchar_t` size matches the
FreeBASIC target `WSTRING` size. Cross-target profiles can set that FreeBASIC
width with `--fbfrog-wstring-size=1|2|4`.
Function-like macros that cast an argument to an integer use private overload
helpers so floating inputs truncate toward zero as C requires; integer and
pointer inputs use their corresponding FreeBASIC cast path. Each macro
parameter occurrence is evaluated once, matching the replacement list.
The generic mapper also recognizes MSVC's signed and unsigned `__int8`,
`__int16`, `__int32`, and `__int64` spellings for casts and declarations.
GNU's `__signed` and `__signed__` keyword spellings map like `signed`,
including Linux header typedefs and body-local declarations and casts.
Whole declarations have a separate 262,144-token bound so macro-expanded
encoding tables do not consume the smaller type-specifier workspace.
Function-pointer cast macros retain `cdecl` and `stdcall` conventions from
GCC-style `__attribute__` groups. Representable C `UL` integer literals map to
`Cast(CULong, ...)`; decimal `f` and `d` floating suffixes map to FreeBASIC's
`!` and `#` suffixes.
Use `--clong32` (or fbfrog's `-clong32`) to map C `long` and `unsigned long`
to 32-bit `Long` and `ULong` for APIs whose binding contract requires that
compatibility choice. This changes the emitted ABI type even on targets where
C `long` is wider.
Repeat `--fb-include=File.bi` to insert an existing FreeBASIC binding before
the generated declarations. This lets type mappings and external record names
refer to project bindings without editing generated output; duplicate include
paths are emitted once.
Repeat `--preserve-include=CHeader=FreeBasicInclude` to map an active C
`#include` to `#include once` for an existing FreeBASIC binding. C2FB reads the
active include directives retained by the preprocessor, emits only mappings
whose directive occurs in a selected source, and omits the mapped header's
flattened declarations and the declarations from its nested C include subtree
while keeping those types available for resolution.
For example, `--preserve-include=common.h=common.bi` reuses `common.bi` when
the configured C preprocessor includes `common.h`. Nested C headers follow
their own mappings or source filters. The C include name accepts `*` and `?`
patterns; otherwise it matches the include operand exactly.
Add `--preserve-missing-includes` when an exact mapped C header may not be
installed. C2FB stages an empty preprocessing stub under a last-resort include
directory, so any real header found by the normal search still takes precedence.
The generated binding keeps the mapped FreeBASIC include; that file must provide
any declarations needed by the rest of the binding. Wildcard mappings do not
create stubs.
Use `--remove-include=Header.h` or fbfrog's `-removeinclude Header.h` to cancel
a selected include mapping. C2FB then flattens that C header's declarations
into the current binding, so removing the FreeBASIC include does not discard
the declarations it represented. Removal matches the quoted or angled
include operand exactly.
For package attribution, pass `-title "Library 1.0" license.txt translators.txt`
to embed the title, original license text, and translator text in the generated
file comment. The long form is `--title="Library 1.0"`,
`--license-file=license.txt`, and `--translators-file=translators.txt`.
C2FB emits one output per invocation, so
the positional output path selects the destination. Title text files are limited
to 1 MiB; comment terminators inside them are made inert before emission.
Generic body conversions also accept --exclude-proc=Pattern to leave selected
C implementations in the linked library while generating candidates for their
peers. The exclusion keeps the procedure declaration available to other
candidates and records why its body was skipped. Use this for platform or ABI
bridges that cannot be represented faithfully in FreeBASIC.
For FreeBASIC on Linux x86-64 with glibc, the opt-in
[`freebasic-linux-glibc-x86_64.rsp`](profiles/freebasic-linux-glibc-x86_64.rsp)
profile supplies CRT includes and mappings for common glibc typedefs, including
`FILE`, `ssize_t`, `fb_off_t`, `wchar_t`, `intptr_t`, and `uintptr_t`. It also
maps glibc pthread mutex, mutex-attribute, and once storage to FreeBASIC's CRT
types, and maps glibc's private 64-bit counter union. The counter mapping
preserves storage but not member names, so use this profile only for that
target.
When translating bodies against bindings generated with this profile, pass the
companion [`freebasic-linux-glibc-x86_64-body.rsp`](profiles/freebasic-linux-glibc-x86_64-body.rsp)
to reuse its target-specific type mappings without forwarding header-only
include options to the C compiler.
For example:

```sh
build/c2fb generic-header include/widget.h widget.bi cc @fb_tools/c2fb/profiles/freebasic-linux-glibc-x86_64.rsp -Iinclude
```

```sh
build/c2fb translate-simple-generic-c src/widget.c widget_candidates.bas cc -Iinclude --fb-source-directory=build/widget-bindings @fb_tools/c2fb/profiles/freebasic-linux-glibc-x86_64-body.rsp
```

Pass `--profile-timings` to generic-body mode to report elapsed time for project
catalog construction, declaration and symbol indexing, function lowering, and
candidate filtering. It changes diagnostics only.

Pass `@options.txt` in `generic-header` to load arguments from a response file.
Each nonblank, noncomment line is one argument; split options such as `-I` and
its path across two lines. Nested response files are supported, with paths
resolved from the current working directory. This is useful for reusing target
flags and mapping lists in batches.
Preserved `#pragma comment(lib, "...")` directives become `#inclib` lines;
repeat `--fb-library=Name` to add a library explicitly. C library filenames
ending in `.lib` or using the `libNAME.a` form are normalized to `NAME`.
Generated procedure identifiers use the selected prefix and retain the C
symbol through `Alias`. Simple scalar, function, and callback typedefs use the
same prefix. Function-type typedef uses that declare external functions are
expanded into `Declare` statements; function-pointer typedefs remain procedure
pointer types. Unknown pointer types become `Any Ptr`; unknown by-value types
keep their C name and need a FreeBASIC declaration from `--fb-include` or before
the generated file is included. Generic-header conversion retains `typedef
void Name;` aliases as `Any` types so pointer uses such as `const Name *` stay
representable in FreeBASIC. When a C header refers to `jmp_buf` without
declaring its typedef, C2FB uses the FreeBASIC CRT type, includes
`crt/setjmp.bi`, and adjusts by-value parameters to `jmp_buf Ptr`. A typedef
found in the C input takes precedence. Top-level functions, callback parameters,
nested function-pointer results, and direct function declarations returning a
callback pointer retain their recognized calling conventions. Ambiguous or
unsupported `stdcall` placements in function parameters and typedefs are marked
as skipped. Variadic `CDecl` callback signatures with a fixed argument followed
by `...` are preserved; multi-level pointers to function pointers use a
generated procedure-type alias. C2FB rejects mapped pointer depths above
FreeBASIC's eight-level limit, and body conversion still rejects calls through variadic
callbacks. Static-linkage functions remain omitted because they do not name
public C symbols. Supported file-scope static objects use `Dim Shared`
module storage without a C symbol alias, including fixed or initializer-sized
arrays and scalar, null-pointer, procedure-pointer, and integer-list
initializers when their C values are supported constants. Narrow character
pointers initialized from string literals use `StrPtr` over compiler-owned
static literal storage, including adjacent literals and embedded NUL bytes.
An exact `{0}` static aggregate initializer uses the zeroed module storage
directly, matching C's static zero initialization without emitting C brace syntax.
Static record initializers also preserve null function-pointer fields; non-null
callback members still need a supported function-designator lowering.
File-scope const record objects use a storage identifier plus a generated
macro that exposes a `Const UDT Ptr` view, avoiding FBC's unsupported direct
`Const UDT` storage declaration.
One-dimensional
`char`, `signed char`, and `unsigned char` arrays accept string-literal
initializers, including adjacent literals, standard escapes, and octal or
hexadecimal escapes that fit in one byte. C's exact-size form may omit the final
NUL; inferred bounds include it. Use `--string=Name` when a selected character
array should use fixed ZString storage. Overlong or unsupported literal forms
remain skipped. Braced static record
initializers and arrays of records are supported for records with scalar
fields and one-dimensional fixed array fields; omitted members are
zero-initialized. Pointer fields accept supported static pointer initializers,
including null constants, addresses, and string literals. Nested records and
callback fields remain outside this initializer subset.
Unsupported static
initializer forms are reported with their declaration. Explicit `struct`,
`union`, and `enum` result types
are accepted on function declarations; function declarations and pointer-cast
macros use `Any Ptr` for incomplete record tags when no FreeBASIC record type
is available.
GNU `asm("symbol")`, `__asm("symbol")`, and `__asm__("symbol")` labels on
external functions and objects keep the C identifier for generated code and
use the selected linker name in `Alias`. Printable ASCII labels and ordinary
C string escapes are supported; labels that need non-printable bytes are
reported as unsupported instead of binding a different symbol.
For Win32 imports whose `stdcall` symbols are undecorated, use `--windows-ms`
or fbfrog's `-windowsms` spelling. C2FB wraps each such procedure in
`Extern "Windows-MS"`, which preserves its alias without FBC's x86 `@N` suffix;
`CDecl` procedures retain their explicit convention.
Simple structs and unions with scalar, pointer, or fixed arrays of up to 16
dimensions use the target's natural ABI alignment;
packed records use `Field = 1`, and `#pragma pack` values 1, 2, 4, and 8 are
applied as `FIELD` caps. FreeBASIC clamps a cap larger than target pointer size
to the default, as recorded in its `parser-decl-struct.bas` source.
GCC's `__extension__` diagnostic marker is removed before declaration parsing;
calling-convention attributes remain mapped, and packed attributes keep their
record layout effect. Record-level `aligned(2)`, `aligned(4)`, and `aligned(8)`
attributes are represented with a one-member union when no packing cap is
active. A typedef carrying `aligned(N)` is emitted as an ordinary alias with a
`Field = N` alignment when `N` raises the target type's natural alignment;
the alias keeps its original `SizeOf`, and record members inherit that alignment.
Lowering a typedef's alignment below its natural type alignment and alignment on
trailing non-typedef objects remain unsupported and are reported. A record
definition's trailing object and function declarators are lowered through the
usual object and prototype paths. Anonymous aggregate results and direct
objects also receive use-site type aliases, so the public FreeBASIC name
reflects the declaration that exposes the otherwise unnamed C type.
Enum types become `Long`, and supported enumerator values become namespaced
FreeBASIC constants. Enum lists may end with C's permitted trailing comma.
Anonymous enums emit their constants without requiring a tag or typedef. C2FB
reuses known nonnegative enum values in fixed array bounds
for typedefs, records, and external objects. Unsupported enumerator expressions
remain skipped and cannot resolve dependent bounds. Literal-only object-like
integer `#define` values become namespaced constants. Expressions that refer to
other macros, enum names, or caller-supplied identifiers remain macros so
forward expansion does not create invalid FreeBASIC constants. Simple
object-like C type macros become `Type` aliases. Generic fixed array bounds can
also fold `sizeof` of scalar, pointer, or fixed-array typedef types when the
active C ABI provides their sizes. Record `sizeof` bounds remain unsupported.
Direct decimal and hexadecimal floating literals in C body candidates become
`Single`, `Double`, or `CLongDouble` according to their C suffix. The literal
spelling is parsed by the target CRT before narrowing, preserving the target's
available precision. Simple casts of these body literals to integer targets
use C's truncation-toward-zero conversion. Object-like macro values support
direct decimal and hexadecimal `Single` and `Double` constants. Hexadecimal
macro constants are converted to bounded round-trip decimal literals, with at
most 256 significand digits, 4,096 intermediate decimal digits, and a binary
exponent magnitude of 8,192. Long-double macro values and macro arithmetic
remain skipped.
Quoted string macros become
`StrPtr` expressions with static string storage; simple object-like aliases to
those strings are preserved as macro aliases. Zero-argument function-like
macros whose bodies are string literals also emit `StrPtr` expressions backed
by static compiler storage.
Wide-prefixed `L"..."` string macros become `WStr(...)` expressions; use a
FreeBASIC target whose `WString` width matches the C target's `wchar_t` width.
Function-like string macros with unused parameters are treated the same way,
including C's adjacent string literal concatenation; their unused arguments
remain unevaluated after macro expansion.
Stringizing macros that combine string literals with `#parameter` segments
retain those segments in the generated FreeBASIC macro body.
A token-checked subset of function-like replacement lists preserves pointer
member access and array subscripts; C unary `&` maps to FreeBASIC `@`, and C
`[]` subscripts map to FreeBASIC's `()` indexing syntax. Parentheses around
the original replacement list remain around the translated expression so
operator precedence is preserved when callers combine macro results.
Simple header function definitions with integer return expressions, a
conservative floating scalar subset, pointer identity/null/offset or narrow
string-literal or simple pointer-cast returns, and direct calls to declared
functions with supported arguments become function-like FreeBASIC macros when
each parameter is used exactly once and no separate prototype must remain.
These macros can read simple record members and fixed-array fields through
pointer parameters; member names remain distinct from parameter names. A single
or nested dereference of a typed integer pointer can return an integer value;
one-level pointer results are also supported when their pointed-to type matches.
Integer-pointer reads also support `p[index]` and `*(p + offset)`. Simple
integer expressions can combine dereferenced values with other integer operands.
Prefix and postfix increment/decrement of by-value numeric parameters preserve
the function result without mutating the caller's argument; pointer parameters
can be incremented in pointer-return expressions.
Known-integer operands also support C `/` and `%`, lowered to FreeBASIC `\` and
`Mod` with C's truncation-toward-zero behavior. Expressions with floating
operands use the floating subset below, including when the C return type is
integer; those return conversions also truncate toward zero. Floating
expressions currently allow decimal or hexadecimal numeric literals, parameters,
parentheses, and `+`, `-`, `*`, and `/`. Explicit casts from these supported floating
expressions to integer types also truncate toward zero. Callback returns support
identity, null, and direct
function designators. Direct callback calls with simple supported arguments are
accepted in scalar-return macros. A forced macro can also select between
callback parameters with a simple conditional expression; more complex callback
expressions remain unsupported. Opaque `void *` offsets use GCC's byte-wise
pointer arithmetic extension.
Numeric-expression and direct-call macro paths cast referenced arguments to
their declared C parameter types; floating-to-integer conversions truncate
toward zero. Substituted parameters are parenthesized. By default, C2FB
requires each parameter to appear once and rejects parameterized short-circuit
and conditional expressions that can defer argument use, so a function call's
argument evaluation is preserved. Repeat
`--force-inline-macro=Pattern` to match fbfrog's more permissive conversion for
selected functions, including unused or repeated parameters and lazy or
conditional expressions. `-forcefunction2macro Pattern` is accepted as an fbfrog
compatibility spelling. This also applies to ordinary function definitions
without a C `inline` specifier. Forced macros can skip, repeat, or conditionally
evaluate side-effecting arguments, so their behavior can differ from C.
Use `--no-inline-bodies` (or fbfrog's `-nofunctionbodies`) to emit declarations
without translating eligible bodies. Existing prototypes are retained once;
static definitions remain private and are omitted when their bodies are
suppressed.
For object-like statement macros and supported function-like statement macros,
`--drop-macro-body-scopes` (or fbfrog's `-dropmacrobodyscopes`) removes a
generated `Scope` around a single translated statement. Supported local scalar
and fixed-array declarations reuse the procedure-body type and bounds checks;
their generated `Scope` remains in place so those names stay local. Unsupported
declaration forms leave the macro untranslated. Unwrapped assignment macros
also become scoped statement macros; lvalues absent from the C header remain
unchanged for a caller-supplied FreeBASIC binding. Simple `if`/`else` blocks
with supported assignment or call arms become FreeBASIC `If` blocks; simple
`while` and `do`/`while` blocks use `While`/`Wend` and `Do`/`Loop While`.
Use `--drop-inline-body=Pattern` or fbfrog's `-dropprocbody Name` to suppress
selected header function bodies; patterns match C function names and accept `*`
and `?`. Public declarations remain available, and generated files report
whether each requested pattern matched.
The force option does not enable unsupported return types, statements, or lazy
parameterized expressions.
Identifier aliases to emitted functions, objects, and representable types
become matching `Declare`, `Extern`, and `Type` aliases. Function-like macros
using supported integer arithmetic, bitwise, and shift expressions, top-level
comparisons, short-circuit logical conditions, or nested conditional operators
become parameterized FreeBASIC macros. Object-like direct calls and simple
function-like calls through an argument are token-lowered as macros. Declared C
callees map to their generated FreeBASIC names; unresolved callees remain
unchanged and must be supplied by an existing binding. Object-like
`defined(NAME)` macros map `NAME` to its generated name when C2FB emits it.
Integer macro and enum expressions also support nested C conditional operators
when their conditions and branches use the supported integer subset. These
lower to lazy FreeBASIC `IIf` expressions,
with Boolean results normalized to C's 1 or 0. Single-byte ASCII C character
constants, including standard, octal, and hexadecimal escapes, use the same
decoder as body expressions. Function-like macros with `/` or `%` remain
skipped by default because their parameters have no declared C types. For
runtime-only macros, repeat `--dynamic-macro-division=Pattern` to emit private
overload helpers selected from the call-site operand types. Integer operands
use C's promotions and usual arithmetic conversions; signed division
truncates toward zero, floating `/` remains floating, and `%` uses integer
operand types. These procedure helpers cannot appear in FreeBASIC `Const` or
other constant-expression contexts.
Parenthesized top-level comma sequences that are used as statement macros lower
to ordered FreeBASIC statements; literal-only comma operands are dropped because
they have no observable effect as statements. Unparenthesized object-like comma
lists remain skipped so initializer lists are not mistaken for statement
sequences. Comma expressions used as macro values and assignments in expression
macros remain unsupported. Use
`--assume-integer-macro=Pattern`
only when every use of a matching macro supplies integer operands. The pattern
matches C macro names and supports `*` and `?`. For supported function-like
expressions, the assumption emits `/` as FreeBASIC `\` and `%` as `Mod`
directly, and it supports compile-time constant expressions. It is also
required to lower statement macros' `/=` operator. Use the assumption only
when floating operands are impossible, because FreeBASIC rounds them before
integer division. Generated files report whether each assumption matched.
Dynamic-division patterns also report whether they matched.
Braced object-like and function-like initializer macros with a supported
comma-separated expression list become parenthesized FreeBASIC macro bodies,
including a trailing C initializer comma.
Scalar, enum, and scalar-typedef C casts lower to FreeBASIC `Cast()` when the
target type is mapped and the operand is in the supported macro-expression
subset. Consecutive scalar casts remain distinct, and supported cast
subexpressions can participate in arithmetic, bitwise, and shift expressions.
Parenthesized `sizeof(type)` and supported `sizeof(expression)` forms become
FreeBASIC `SizeOf` expressions, including pointer-to-callback typedefs and
complete tagged records whose layouts C2FB emitted.
For an object-like macro that invokes a function-like macro, use
`--expand-macro=Pattern` to substitute that call before expression lowering.
`LL` and `ULL` integer
suffixes retain their 64-bit width in these generic expressions when the literal
fits that type, which matters for shifts before a cast narrows the result.
Microsoft-style integer macro suffixes `i8`, `i16`, `i32`, `i64`, `ui8`,
`ui16`, `ui32`, and `ui64` are normalized to FreeBASIC literals with matching
wide suffixes where available.
Mapped C pointer casts lower to `CPtr()` when the operand is atomic, a direct
function call, or an unambiguously grouped expression. Uppercase macro
parameters can supply pointer-cast types such as `T *`; this avoids treating
ordinary lowercase value parameters as types. Casts through known callback
typedefs and resolvable inline function-pointer signatures are supported.
Unsupported callback signatures,
record-by-value casts, out-of-range long-long literals, and casts with ambiguous
operand boundaries remain skipped. Narrow string-literal casts to `char *`,
byte-pointer, or `void *` targets use static `StrPtr()` storage followed by a
typed `CPtr()`.
Equality tests between a declared pointer object and a recognized C null-pointer
constant become FreeBASIC Boolean expressions with C's 1/0 result convention.
Constant-only unsigned-int expressions using `+`, `-`, `*`, and bitwise
operators are wrapped to 32 bits. Uncast unsigned expressions involving comparisons,
shifts, division, wider suffixes, or unresolved identifiers remain skipped so
the converter does not silently change C integer promotions.
Object-like macros made only of identifiers and string literals are also
token-lowered when multiple tokens are adjacent. Unknown identifiers stay
unchanged and must be supplied by an existing FreeBASIC binding.
Object-like macros with one `##` between unresolved identifiers are lowered by
folding the pasted name before emission. C2FB leaves pastes involving known or
renamed C symbols unsupported so the generated binding cannot lose a rename.
Object-like macros whose complete replacement is a function-pointer type, such
as `#define CallbackType int (*)(int)`, emit a named FreeBASIC procedure-pointer
type after C2FB parses the callback signature. Other partial declaration macros
remain unsupported.
Token pasting is skipped by the parsed automatic path because its result is
formed at macro expansion time, after C2FB's prefix
and rename mappings have been applied. Stringizing macros whose whole
replacement is `#parameter` or `#__VA_ARGS__`, or whose stringized parameter is
an argument to a simple function-call wrapper, use FreeBASIC's native
stringizing syntax. Simple function-like macros that expand to one
call of a declared C function are also emitted when their arguments are
supported macro parameters, constants, or strings. Variadic wrappers can ignore
their trailing arguments or forward the complete `__VA_ARGS__` list to that
function; GNU named variadic parameters such as `args...` are retained as
FreeBASIC variadic parameters. Other uses of `__VA_ARGS__` remain skipped.
Statement macros using `{ one_call(); }` or `do { one_call(); } while (0)` are
lowered for direct call syntax; declared functions use generated names, and
unresolved callees remain unchanged for an existing binding to define. Simple assignments and
comma-separated or semicolon-separated sequences of assignments and declared
function calls become scoped FreeBASIC macro blocks. Assignment targets must be
macro parameters, declared scalar objects, or known direct record members.
Leading `(void)` casts are removed when the remaining statement is supported.
The GNU `ignore_value` statement-expression shape that captures a direct
function call in a `__typeof__` local and then discards that local is lowered
to one call statement. Other chained assignments and statement expressions
remain skipped when their evaluation or result cannot be preserved.
Single `if (condition) one_call();` statement macros also lower to FreeBASIC
`#macro` blocks when their condition and call can be translated. Call arguments
support member access, pointer indexing, and simple arithmetic. Direct member
access on a declared object is checked against its emitted record layout; member
names on macro parameters are preserved because their type comes from the call
site. Unknown bases, known array-valued fields, `else` branches, and multiple
statements remain skipped.
For object-like or function-like macros outside that subset, repeat
`--replacement-file=Rules.rpl` in `generic-header`. The existing
`convert c:` / `to c:` / `to fb:` format matches the complete C macro definition
by tokens, so whitespace differences do not matter. A `to c:` body returns to
the supported C macro translator; a `to fb:` body is emitted directly, with
function-macro parameters renamed to generated FreeBASIC parameters. Indented
multi-line `to fb:` bodies become `#macro` blocks.
For macros whose bodies are outside the parsed subset, repeat
`--convert-macro-tokens=Pattern` to translate tokens without parsing the body;
the fbfrog spelling `-convbodytokens Pattern` is accepted as an alias. This
maps C operators, integer bases, strings, and known C names while preserving
punctuation such as `#` and `##`. It does not expand C macros or validate the
resulting FreeBASIC syntax by itself; use `--expand-macro=Pattern` to request
C-preprocessor expansion first. Select specific macros and inspect the emitted
body. If standard preprocessing fails and token conversion was requested,
C2FB retries with traditional compiler preprocessing. Other inputs can request
the same retry with `--traditional-cpp-fallback`. The generated file notes when
that fallback is used. A tokenization failure is reported as an unsupported
selected macro.
Unresolved or unsupported integer-like expressions are marked as skipped. Skip
comments include up to 240 characters of the original macro definition to make
manual follow-up easier.
Unsupported enumerator expressions and later implicit values in the same enum
are marked as skipped. Struct and union fields support
comma-separated declarators that share a common type, including pointers and
fixed arrays of up to 16 dimensions.
Top-level external scalar and pointer objects are emitted with C symbol aliases;
fixed arrays are emitted with each declared bound, including dimensions
composed from an array typedef and an object declarator. Unsized one-dimensional
arrays use an aliased first-element declaration and an indexed
macro, following fbfrog's strategy for arrays whose bound is not present in the
header. Repeat `--array-size=CName[.field]=Count` to supply an integer
constant from 1 to 2,147,483,647 for an unsized external array or flexible
record member. Generic-body mode also accepts qualified hints for block-local
flexible-array record members. The emitted local field comment records the
chosen extent; compare the resulting record layout with the active C ABI before
using `sizeof` results. A FreeBASIC `Len("...")` string literal expression is
also accepted for fbfrog `-setarraysize` compatibility. In generic-header mode,
C2FB emits fixed-bound `Extern` declarations for external arrays and calls out
unmatched size hints in the generated file. For a flexible record member, the
qualified `CRecord.field` form targets that member without applying the same
hint to identically named fields in other records.
Hints also size flexible array members and the leading dimension of a
multidimensional external array. A hinted flexible array member expands the
FreeBASIC record size even though C `sizeof` excludes that trailing storage;
the generated field comment calls this out.
Each dimension and the total element count are capped at 2,147,483,647;
FreeBASIC also checks total object size using the element type's storage size.
This adapts fbfrog's `-setarraysize` hint for C2FB's generic-header path.
`--fix-unsized-arrays` implements fbfrog's `-fixunsizedarrays` behavior for
unsized character arrays, exposing them through a `ZString` pointer accessor;
other incomplete arrays retain indexed macros. An explicit `--no-string`
override keeps character arrays indexed.
Comma-separated object and function declarators are handled individually.
Function-pointer objects with supported CDecl or StdCall signatures become
FreeBASIC procedure pointers. This includes nested pointer-to-function results
whose declarator alternates pointer and function operators, with each layer's
calling convention retained; unsupported callback shapes and multidimensional
callback arrays are marked as skipped.
Alternating anonymous `struct`/`union` members become nested anonymous
FreeBASIC `Type`/`Union` blocks. Same-kind anonymous nesting uses a single-member
wrapper of the opposite kind, which preserves the nested layout and promoted
field access while satisfying FreeBASIC's alternating-block rule. An inline
anonymous `struct`/`union` followed by several field declarators uses one helper
layout for its named, pointer, or callback fields. A tagged nested `struct`, `union`, or
`enum` definition, including one inside an anonymous inline aggregate, is hoisted
to its own generated type so later fields and declarations can use the tag. Fixed
multidimensional record fields retain their individual bounds; unsized
multidimensional arrays remain unsupported. A
record typedef's comma-separated declarators are lowered individually. C2FB uses
an available by-value alias as the record type, then maps sibling aliases such
as pointers and callbacks to that type. Callback aliases returning records by
value are emitted after the complete record layout so FreeBASIC can validate
the signature. Function typedefs that return callback pointers are emitted as
callable prototypes when used to declare a function, including nested calling
conventions. An anonymous record group with only pointer or function
declarators remains unsupported because it provides no by-value type name. A
GCC zero-size named empty record is emitted as a type alias to `Any`; this
preserves `SizeOf` and pointer references. By-value objects, fields, parameters,
and results using that empty-record alias are skipped because FreeBASIC cannot
store or pass an `Any` alias by value. A
trailing zero-length or flexible (`[]`) `char` or `unsigned char` array is
omitted from storage; the generated comment names a `*_tail_ptr` macro that
computes its address from a pointer to the containing record. Generic body
translation uses that accessor for reads and writes through the flexible byte
member. A typedef to an incomplete byte array is accepted in the same
final-member position. Non-byte
or multidimensional flexible arrays, by-value long-double fields, or
unsupported field alignment are skipped. Named
integral bitfields are emitted when the C and FreeBASIC storage extents match;
zero-width or unsupported bitfields and runs leaving unused storage bytes before
a later member are skipped because FreeBASIC advances to the full unit while
some C layouts place the next member in its unused bytes. FBC defaults to
GCC-style bitfield layout. When targeting an MSVC-compatible C layout, wrap the generated
include in `#pragma push(msbitfields)`, `#pragma msbitfields true`, and
`#pragma pop(msbitfields)`. The FreeBASIC CRT's byte-backed `CLongDouble`
storage preserves size but does not carry target C long-double field alignment.
By-value fields depending on an unsupported record layout cause their containing
record layout to be skipped as well; pointer fields can remain opaque.
FreeBASIC field names are case-insensitive, so C fields that differ only by
case receive a trailing underscore in the generated layout. Generic record
emission keeps a per-record name index instead of rescanning every prior field
for each collision check. A regression crosses the index's initial capacity
with a 6,600-field record and verifies both end members.
The C preprocessor selects conditional branches using the supplied target
options. Fixed multidimensional array typedefs and objects retain every bound,
and dimensions from an object declarator are appended to dimensions from its
typedef. Function parameters of one-dimensional array typedefs decay to element
pointers.
Supported multi-declarator typedef statements are split into separate aliases.
Unsized multidimensional arrays and complex multi-declarator typedefs remain
unsupported.

For example:

```sh
build/c2fb generic-header include/widget.h widget.bi cc -Iinclude -DWIDGET_VERSION=2
```

preprocesses and converts one configured header.

For headers with different APIs or layouts across targets, use the target matrix
runner to produce one binding per compiler profile. Add `combined_binding` and
a `freebasic_condition` for every profile to also emit one selector `.bi` that
includes the binding matching the current FreeBASIC target or API version.
ABI-specific record layouts remain in their profile files, so the selector can
preserve each layout without merging incompatible records. The conditions use
FreeBASIC preprocessor
syntax and should be mutually exclusive and cover every target that includes
the selector. A target with no matching profile receives a compile-time error.
This provides one include point for the same multi-target workflow that fbfrog
offers while keeping ABI-specific record layouts in separate files. Paths in
the JSON manifest are relative to the manifest's directory; the top-level and
profile `input` values, profile `headers`, `output_directory`, and path-like
`converter` use that base. Compiler options run from the manifest directory.
Shared and profile-specific C2FB options are separate from compiler options:

The matrix can also select different C headers for API versions or other
variants. Keep top-level `input` as a default when most profiles share a header;
set profile `input` to override it, or use profile `headers` for a header list.
The first header is the primary input and later headers are preprocessed through
C2FB's `--c-include` path. Set `freebasic_condition` to a version macro test, for
example `C2FB_API_VERSION = 2`, and pass the matching C `-D` option in that
profile's `compiler_options`.

```json
{
  "input": "include/widget.h",
  "output_directory": "build/widget-bindings",
  "combined_binding": "widget.bi",
  "converter": "fb_tools/c2fb/build/c2fb",
  "c2fb_options": ["--prefix=widget_"],
  "compiler_options": ["-Iinclude"],
  "profiles": [
    {
      "name": "linux-x86_64",
      "compiler": "cc",
      "freebasic_condition": "defined(__FB_LINUX__) AndAlso defined(__FB_64BIT__)",
      "compiler_options": ["-m64"]
    },
    {
      "name": "windows-x86_64",
      "compiler": "x86_64-w64-mingw32-gcc",
      "freebasic_condition": "defined(__FB_WIN32__) AndAlso defined(__FB_64BIT__)"
    }
  ]
}
```

Run it with `python3 fb_tools/c2fb/c2fb_target_matrix.py c2fb-targets.json`.
The runner writes `linux-x86_64.bi`, `windows-x86_64.bi`, and the `widget.bi`
selector beneath the output directory. A profile may also provide
`c2fb_options`, for example to map a target-specific C type. All profiles must
convert successfully before any new bindings are published. Consumers can
include `widget.bi` and let its target conditions select the profile, or include
one profile file directly.

For distinct API-version headers, omit top-level `input` and define the profile
header set directly:

For one header with a C preprocessor version macro, `version_matrix` expands
the version values into profiles automatically. Each profile receives
`-D<macro>=<value>`; the combined binding uses the matching FreeBASIC
condition. Values are decimal integers without leading zeros. Common
`compiler_options` and `c2fb_options` still apply to every version.

```json
{
  "input": "include/library.h",
  "output_directory": "build/library-bindings",
  "combined_binding": "library.bi",
  "converter": "fb_tools/c2fb/build/c2fb",
  "version_matrix": {
    "macro": "LIBRARY_VERSION",
    "values": [1, 2, 3],
    "name_prefix": "library-version",
    "compiler": "cc"
  }
}
```

This produces `library-version-1.bi`, `library-version-2.bi`,
`library-version-3.bi`, and a selector using `LIBRARY_VERSION = N`. Use
`freebasic_condition_template` or `compiler_option_template` when the C and
FreeBASIC version selectors need different spellings.

For migration from a fbfrog script, `fbfrog_version_script` expands one
`-declareversions` directive and `-declarebool` selectors into API profiles.
Nested `-selectversion`, `-selectdefine`, and `-ifdef` blocks choose the
`-define` directives applied to each profile. Commands may share a line or span
lines. C2FB emits a FreeBASIC selector condition for every version and boolean
combination, up to the 256-profile matrix limit, and rejects unsupported script
commands before publishing files. A `-define NAME` with no body remains an
empty C macro, matching FBFrog's `#define NAME` behavior. For example, the
adapter handles versioned
ANSI/Unicode and static/shared API variants in one binding.

Bare header paths in the script become profile inputs, relative to the script
file. A top-level `input` is included in every profile as a common header and
may be omitted when the script supplies its own inputs. The adapter also handles
`-include`, `-fbfroginclude`, `-incdir`, `-target`, `-iftarget`, and
`-selecttarget`. `-fbfroginclude` preincludes the C header for macro and type
resolution while filtering its declarations out of the generated binding.
`generic-header` accepts FBFrog's global `-v` option, and scripts preserve it
through every selected profile. One `-v` prints the input, output, and
preprocessor stage; `-v -v` also prints the preprocessor options and
declaration/macro collection counts. Target profiles identify a concrete
fbfrog OS/architecture, compiler, and FreeBASIC
condition. C2FB supplies the matching `__FB_*__` and platform aliases such as
`__linux__` and `_WIN32` to the C preprocessor; the condition defaults to the
matching FreeBASIC OS, bitness, and architecture macros. It first undefines
conflicting host-compiler platform macros, so ordered `#elif` target branches
select the requested profile. It also replaces host compiler size and wide
character predefined macros with FBFrog's target model, including pointer,
`long`, `long double`, `wchar_t`, and fixed-width integer type macros, so those
preprocessor branches do not silently follow the host ABI. This reproduces
FBFrog's preprocessing model; use a matching cross compiler and sysroot when
the actual target ABI or system header layout matters. Profiles also use
FBFrog's GCC/Clang compatibility version macros and `__GNUC_PREREQ` behavior;
Clang's `__has_feature` builtin is normalized to FBFrog's false result. Within
Windows and Cygwin profiles also provide FBFrog's calling-convention and
`__declspec` aliases, and target label prefixes follow FBFrog's model. Windows
profiles also set `_INTEGRAL_MAX_BITS` and `_REENTRANT`. Predefined macros with
empty bodies remain empty. Within each selected
API path, common binding policies
such as `-renameproc`, `-renametypedef`, `-removeproc`, `-removevar`,
`-setarraysize`, `-string`, `-ifndefdecl`, and `-dontemit` map to C2FB's
generic-header options. The adapter also maps the related rename, removal,
include, macro, and calling-convention options that C2FB implements.
Global `-emit Pattern Name.bi` pairs split declarations into separate outputs;
patterns are checked in script order, and the first match owns that source.
When target or API variants exist, C2FB emits a selector per destination and
profile files beneath it; a single unversioned configuration writes each
destination directly. An `-emit` destination can be a `.bi` file name, a
relative `.bi` path, or an absolute `.bi` path. Relative paths are rooted in
the selected `-o` directory or manifest `output_directory`. Each selector and
its profile files are written beside that destination. Nested `.fbfrog` scripts
and `@file` argument files are expanded;
relative input, include, and metadata paths resolve from the file that declares
them. fbfrog collects `-emit` mappings while parsing, so placing an `-emit`
inside `-ifdef` or `-select` does not make its routing conditional.
When `fbfrog_version_script.targets` is omitted, C2FB uses FBFrog's default 23
OS/architecture targets and defaults the preprocessing compiler to `cc`.
Script `-target` options filter that set. Supply explicit target descriptors
when each target needs its own compiler or ABI flags; set `targets` to an empty
list for one generic profile without target selectors. The default target set
uses preprocessor definitions to select platform branches. Use matching
cross-compilers or ABI flags when relying on measured foreign record layouts.
Multiple `-target` values combine their OS and architecture sets, matching
FBFrog's behavior; for example, `linux-x86` and `win64` select four profiles:
Linux x86/x86-64 and Windows 32/64-bit.

Matrix manifests default to 256 profiles, matching FBFrog's API-combination
limit. Set top-level `max_profiles` to a value from 1 through 4096 when a
matrix needs more combinations. Eight independent boolean selectors require
256 profiles for one generic target; the default 23-target expansion multiplies
that count. The bound applies to the expanded matrix before conversion starts.
An fbfrog `-o` path selects the matrix output location: a `.bi` file name sets
the combined selector name and parent directory, while an existing directory
sets the output directory and uses the first input header's stem for the
selector unless `combined_binding` is supplied. In this case the manifest may
omit `output_directory` when every output destination has an explicit `-o`
directory or absolute path; the script's `-o` location takes precedence when
both are present. Before `-emit`, an existing `-o` directory applies to
subsequent emitted bindings. Each emitted destination can use its own existing
`-o` directory; relative destinations without one use the manifest's
`output_directory`. Profile files and selectors are staged in the directory
where each file will be published.

```json
{
  "output_directory": "build/library-bindings",
  "combined_binding": "library.bi",
  "converter": "fb_tools/c2fb/build/c2fb",
  "fbfrog_version_script": {
    "path": "library.fbfrog",
    "name_prefix": "library",
    "targets": [
      {
        "name": "linux-x86_64",
        "fbfrog_target": "linux-x86_64",
        "compiler": "cc"
      },
      {
        "name": "windows-x86",
        "fbfrog_target": "win32",
        "compiler": "i686-w64-mingw32-gcc"
      }
    ]
  }
}
```

Global `-title` metadata, including its license and translator files, maps to
C2FB's generated-file metadata. Destination-specific `-title`, `-addinclude`,
`-inclib`, and `-undef` are routed to their matching `-emit` destination.
Unqualified addinclude/library/undef options apply to the first emitted binding,
matching fbfrog's default destination. Options for unknown destinations are
rejected before output is published. Use explicit C2FB profiles for scripts
that need routing behavior beyond fbfrog's global `-emit` mappings.

```json
{
  "output_directory": "build/library-bindings",
  "combined_binding": "library.bi",
  "converter": "fb_tools/c2fb/build/c2fb",
  "profiles": [
    {
      "name": "version-1",
      "headers": ["include/library-1.h", "include/library-common.h"],
      "compiler": "cc",
      "compiler_options": ["-DLIBRARY_VERSION=1"],
      "freebasic_condition": "LIBRARY_VERSION = 1"
    },
    {
      "name": "version-2",
      "input": "include/library-2.h",
      "compiler": "cc",
      "compiler_options": ["-DLIBRARY_VERSION=2"],
      "freebasic_condition": "LIBRARY_VERSION = 2"
    }
  ]
}
```

To bind a C typedef to an existing FreeBASIC type, add a mapping before the
preprocessor options:

```sh
build/c2fb generic-header include/widget.h widget.bi cc --type-map=WidgetHandle=WidgetHandle -Iinclude
```

To resolve a FreeBASIC naming conflict without changing the C symbol:

```sh
build/c2fb generic-header include/widget.h widget.bi cc --rename=Type=WidgetType -Iinclude
```

Header emission and body-symbol discovery use a bounded recursive declarator
parser. It tracks how pointer, array, and function operators bind around the
declared name, including grouped forms such as
`int (*factory(int))(void)`. This follows the recursive grammar approach used
by fbfrog while keeping C2FB's parser and supported type rules local to the
converter. The prototype emitter supports a direct function returning a
callback pointer and deeper return chains when each layer alternates pointer
and function operators. It preserves the outer function and each returned
callback's convention separately. Generic external objects and function-pointer
typedefs support the same nested CDecl or StdCall result chains. Other function
return declarators remain unsupported. This does not imply full C declarator
or function-pointer body support. Body-symbol indexing
uses the same parsed function and parameter groups, and records a
function-pointer result as an opaque pointer with its pointer depth intact.

The `functions` mode scans C implementation files under a source directory and
emits a CSV index of function names, source line spans, and rough size classes.
Pass `--include-headers` to scan `.h` definitions after `.c` files, adding header
functions only when the name was not already indexed from a C source. It
skips continued preprocessor directives and records alternate
conditional definitions of the same function once, including declarations that
return function pointers. It also skips upstream test-support sources; function
port status starts as `Needs mapping` so it can be reconciled against the
FreeBASIC source tree.
Files are ordered by relative path within each extension group, so the generated
index does not depend on filesystem enumeration. With `--include-headers`, C
definitions remain first and header definitions are appended afterward.

For function indexing, each `#if`/`#elif`/`#else` branch starts from its
conditional group's structural state, so braces in one branch do not hide
definitions that follow or appear in another branch. The scanner unions branch
definitions by C function name; it does not evaluate feature macros or verify
that every branch compiles.

The `reconcile-functions` mode scans top-level `.bas` and `.bi` files for
procedure definitions and records both each FreeBASIC procedure name and its C
`Alias` name. Declarations without bodies do not count. Matching either name
updates the row to `FB body present`. This records body coverage; it does not
claim that all C behavior or call paths have been ported. Other manually
assigned statuses are preserved.

`translate-simple` emits reviewable candidates for a conservative statement
subset: scalar local declarations, assignments, `if`/`else`, `while`, `for`,
`do`/`while`, `return`, standalone calls, and switches whose case bodies use
supported statements. C fallthrough and a `default` label shared with case
labels use an explicit state machine. Switch branch storage grows as needed
up to 8,192 branch groups, covering large opcode dispatch tables such as
SQLite's VDBE. Multiple declarators, mixed
pointer/scalar declarations, and comma-separated statement or
`for` step lists retain their C order. `break`, `continue`, and named `goto`
statements use procedure-local targets. A `for` continue executes its increment
before testing the condition again. Nested block and `for` scopes keep shadowed
locals distinct.
Body-local `unused`, `maybe_unused`, and `nonstring` attributes are removed
because they affect diagnostics rather than storage layout or runtime
behavior. Other GNU attributes remain attached to the declaration and are
rejected if C2FB cannot preserve their effects.
Expression lowering sequences right-associative `=` assignments and preserves
their stored value in returns and loop conditions, including pointer chains
whose right-hand side calls a C function. The regression compares these forms
with C on native and GCC FreeBASIC backends.
Direct `__builtin_alloca(size)` calls lower to procedure-owned heap blocks so
each allocation remains valid until the C function returns, including repeated
calls from a loop. Generated cleanup runs before each translated return and on
normal fallthrough; return expressions are evaluated before that cleanup. C2FB
checks the size before adding its allocation header and reports allocation
failure with FreeBASIC runtime error 7. This preserves function-scope pointer
lifetime, but uses the heap rather than the C stack, so allocation pressure and
failure behavior differ. Direct `longjmp`, `_longjmp`, `siglongjmp`, and
`__longjmp_chk` calls in a function using `__builtin_alloca` are rejected because
they bypass the generated cleanup. Alignment-specific `__builtin_alloca` forms
remain unsupported.
An unused block-local `struct` or `union` definition is omitted when its tag
does not occur later in the function; such a declaration allocates no storage.
Simple block-local struct and union definitions, named or anonymous, receive a
private generated FreeBASIC `Type` or `Union` when used by declarations in
the function. Scalar, pointer, and callback fields, fixed field arrays, and
mapped nested record fields are supported; nested inline definitions,
bitfields, and variable-length fields remain outside this path.
Complete file-scope records can also retain recognized CDecl callback-pointer
fields in their generated private layouts, preserving offsets of later members.
Function typedefs retain their callback signatures in body lowering, including
fixed-size automatic and static callback tables initialized with known
functions and called through indexed entries.
Mapped C record tags can be used in separate local declarations and in
`sizeof(struct Tag)` expressions. C2FB resolves these to existing FreeBASIC
layouts; it does not infer a missing layout or claim C/FreeBASIC size parity.
The default body mode emits the SQLite port's type includes and uses its C ABI
aliases. `translate-simple-generic` and `translate-simple-generic-tree` use the
same candidate translator without SQLite includes. `translate-simple-generic`
and `translate-simple-generic-tree` consume preprocessed input without source-
origin filtering. The `-c` modes preprocess raw C with the selected compiler
and track source markers, so header bodies are not treated as root definitions.
The C preprocessor target must match FreeBASIC. Raw modes accept compiler and
preprocessor arguments, plus an
optional FreeBASIC source directory for project types and declarations.
External inline definitions in included headers still contribute callable
signatures when their bodies are not selected. Their external implementations
must be provided by another translated module or linked library.
`--include-global-definitions` emits file-scope C object definitions with their
original linker names. Static objects retain module-private storage; non-static
objects use FreeBASIC shared storage and `Alias`. The option enables preprocessor
source markers to distinguish implementation files from included declarations.
Repeat `--type-map=CName=FbType` to bind a C type name to an existing FreeBASIC type.
The source directory also supplies the `.bi` include for a referenced typed
external object when that file defines its record layout.
If a C implementation file declares private record types that its header does
not expose, use `c2fb_source_unit.py` to build its local type context and
translate its bodies in one step. It runs `generic-header` with
`--exclude=*`, keeps that source file's private objects in module-private
storage, and uses an `--emit-source` pattern for the C file. Body conversion
reuses those declarations by their recorded C names, avoiding a second copy of
mutable state. Existing FreeBASIC bindings are indexed alongside the generated
context. The type-only pass keeps scalar typedef dependencies referenced by
selected records and module-static objects, including typedef chains defined
in included headers. With `--tree`, each C file receives its own private object
storage, even when different files use the same static variable name. The
generated context also retains pointer-only aliases for forward tags referenced
by selected records, so filtering out a tag's full definition from another
header does not leave an undefined FreeBASIC type name.
By default, the source-unit driver requests forward aliases for every C tag.
When an existing FreeBASIC interface already supplies the required record
types, `--no-forward-declarations` omits that wildcard request. Keep any needed
incomplete tags with explicit `--header-option=--forward-decl=Pattern`
arguments, and use `--type-map` plus the FreeBASIC source index when the C body
should refer to existing FreeBASIC layouts and helper interfaces.
When a translated body accesses a record defined by an included header, pass
`--include-header-types` to include type declarations from all preprocessed
source paths in the generated context. This keeps functions, objects, and
macros filtered while allowing C2FB to emit supported header record layouts.
The type context may be larger because it includes records from the target's
system headers; unsupported layouts remain reported for manual handling.
Body conversion accepts incomplete external arrays such as `extern T values[]`
without inventing an extent; it binds the C symbol at its first element and
preserves indexed access. C `sizeof` on that incomplete array remains invalid.
`--reuse-static-object=CName=FbName` is also available to body conversions
that use an existing FreeBASIC object for a C file-local static; the named
FreeBASIC storage must already be indexed.
It writes the reviewed type context beside the candidate and keeps indexing
copies in a temporary directory:

```sh
source_root=/path/to/fbc/src
python3 fb_tools/c2fb/c2fb_source_unit.py \
  "$source_root/sfxlib/sfx_midi_fm.c" \
  build/sfx-candidates/sfx_midi_fm.bas \
  --converter=fb_tools/c2fb/build/c2fb --compiler=cc \
  --fb-source-directory=build/sfx-context \
  --header-option=--fb-include=fb_sfx.bi \
  "--header-compiler-option=-I$source_root/rtlib" \
  "--header-compiler-option=-I$source_root/sfxlib" \
  "--body-compiler-option=-I$source_root/rtlib" \
  "--body-compiler-option=-I$source_root/sfxlib"
```

C2FB does not merge source-private types into an existing FreeBASIC layout
automatically. When the existing layout uses C2FB's conventional `c2fb_`
record name, body conversion binds it to a C record tag if a corresponding
member exists in both models. This reuses the supplied field storage and does
not synthesize missing layout members. Use `--type-map` when a different
FreeBASIC name is required. For a final C flexible-array member on a mapped
generated layout, body conversion uses the conventional `_tail_ptr` accessor
name; the supplied type context must define that accessor and its storage
field. Body conversion can also generate a private `Type` for a complete,
unambiguous, unpacked source struct whose members have supported scalar or
pointer types, fixed one-dimensional arrays, and nested records whose layouts
are already known. The generated type is emitted only when an accepted
candidate uses it. Variable-bound or multidimensional struct members, unknown nested layouts,
unions, bitfields, packed layouts, and volatile members still need an existing
layout or manual work. This bounded path does not claim that arbitrary
generated layouts match the C ABI; compile and compare each candidate before
integrating it.

When `__builtin_offsetof` resolves to a flexible member represented by the
generated tail accessor, the body casts its address directly to `c2fb_size_t`.
That keeps the conversion pointer-sized on both 32-bit and 64-bit FreeBASIC
targets.
Add `--tree` and pass a C source directory plus a candidate output directory
to apply this two-pass conversion to the selected `.c` files recursively.
Candidate paths preserve the source tree layout, and each file receives a
separate type context, so identical private tag names in different C files stay
isolated:

Repeat `--source-pattern=Pattern` to select only matching source-relative paths;
patterns are combined as a union and accept `*` and `?`. A pattern that selects
no C files is an error. Without source patterns, tree mode processes every `.c`
file below the input directory. `--jobs=N` runs up to N independent source units
at once (1 to 32, default 1). Each unit publishes its type context and body
candidate only after both passes succeed. If candidate publication fails, the
prior type context is restored or the new one is removed. Reports remain in
source order by default. Add `--progress` to report each unit's generic-header
and body conversion start/completion on stderr with elapsed time, then report
the completed file. The next unit is scheduled as soon as a worker finishes;
per-unit report blocks follow completion order. Candidate paths and the final
summary are unchanged. The final summary includes the selected C-file count,
failed-unit count, translated simple-procedure count, and unsupported or
duplicate candidate count. These counts describe generated candidates; tree
mode does not compile or link the resulting FreeBASIC files.
Add `--report-json=PATH` to write a versioned, deterministic per-source report.
It separates successful candidate generation from files that actually contain
translated procedures, records translated and skipped procedure counts for
each input, and includes diagnostics for failed units. A generated candidate
can still contain skipped functions and must be compiled and reviewed before
it replaces C code. Failed entries also record the source-unit exit code, even
when a subprocess did not write a diagnostic.
Each generated unit also records `body_diagnostic_counts`, a histogram of
diagnostic reason codes embedded in its candidate. The report totals combine
those histograms, and the console ranks the most frequent reasons first. This
is an actionable breakdown of conversion diagnostics; its counts do not replace
the skipped-candidate count because duplicate candidates may have no body
diagnostic.
When the type pass rejects an
external C++ thread-local object, the runner lists its name so dependent body
rejections can be traced to the missing binding.

```sh
python3 fb_tools/c2fb/c2fb_source_unit.py \
  /path/to/project/src build/candidates --tree --jobs=4 --progress \
  --source-pattern='rtlib/strings/str_*.c' \
  --body-option=--rename-proc-prefix=c2fbPorted_ \
  --converter=fb_tools/c2fb/build/c2fb --compiler=cc \
  --fb-source-directory=build/bindings \
  --header-compiler-option=-I/path/to/project/include \
  --body-compiler-option=-I/path/to/project/include
```

Use `--unit-manifest=options.json` when different C files need different
defines, type maps, or include paths. Profiles match source-relative paths;
all matching profiles append their options in manifest order:

```json
{
  "version": 1,
  "profiles": [
    {
      "pattern": "linux/sfx_linux.c",
      "header_options": [
        "--emit-source=fb_sfx_linux.h",
        "--emit-source=struct_timespec.h"
      ],
      "header_compiler_options": ["-I/path/to/fbc/src/sfxlib/linux"],
      "body_compiler_options": ["-I/path/to/fbc/src/sfxlib/linux"]
    }
  ]
}
```

Unit profiles can also set `fb_source_patterns` to choose the `.bi` and `.bas`
files indexed for that C source, plus `fb_source_recursive` and
`fb_source_include_closure` to scan nested paths and follow their local quoted
includes. These fields require `--fb-source-directory`, and keep each source
unit's binding catalog independent in larger projects.
Set `no_forward_declarations: true` in a unit profile, or pass
`--no-forward-declarations` for the whole tree, to omit the default wildcard
forward-tag aliases from the generated type context. Use explicit
`header_options` such as `--forward-decl=TagPattern` for the incomplete tags
the candidate still needs; `--type-map` and the indexed FreeBASIC interfaces
can supply project-owned types instead.

When source filtering omits an enum declaration from the local type context,
references to its known enumerators are lowered to their integer values. This
also applies to file-scope initializers, so generated storage does not refer to
an enum name that the filtered binding omitted.

Pass `--fb-source-recursive` to index nested `.bi` and `.bas` files while
preserving their relative include paths, for source trees such as the compiler's
`inc/crt` bindings. Recursive scans omit common generated directories such as
`build`, `out`, `.git`, and `node_modules`.

When a project already has many FreeBASIC bindings, repeat
`--fb-source-pattern=GLOB` to index only matching `.bi` and `.bas` paths
relative to `--fb-source-directory`. Patterns form a union. Add
`--fb-source-include-closure` to follow local quoted includes transitively;
when an included `.bi` is owned by a sibling `.bas` that includes it, that
implementation is staged too. This keeps unrelated bindings out of each C
source unit while retaining the declarations and implementations it needs.
Use `--fb-source-recursive` when the selected files are in subdirectories. The
selected files and their closure share a 32,768-file limit.
Indexed files must resolve inside `--fb-source-directory`; symlinks whose
targets escape that tree are ignored. Copy generated bindings into the indexed
directory when they are produced elsewhere.

```sh
python3 fb_tools/c2fb/c2fb_source_unit.py \
  src/platform.c build/candidates/platform_candidates.bas \
  --converter=fb_tools/c2fb/build/c2fb --compiler=cc \
  --fb-source-directory=fb_src \
  --fb-source-pattern='sqlite3_os_*.bi' \
  --fb-source-include-closure
```

The optional FreeBASIC source check also sweeps every root `sfx_*.c` module with
[`freebasic-sfxlib-linux-x86_64-units.json`](profiles/freebasic-sfxlib-linux-x86_64-units.json).
That manifest emits the `timespec` and MP3 layouts only for units that use them,
and keeps glibc's `isdigit` macro as a callable function for `sfx_play.c`:

```sh
source_root=/path/to/fbc/src
python3 fb_tools/c2fb/c2fb_source_unit.py \
  "$source_root/sfxlib" build/sfx-candidates --tree \
  --source-pattern='sfx_*.c' \
  --unit-manifest=fb_tools/c2fb/profiles/freebasic-sfxlib-linux-x86_64-units.json \
  --converter=fb_tools/c2fb/build/c2fb --compiler=cc \
  --header-option='--emit-source=*fb.h' \
  --header-option='--emit-source=*fb_*.h' \
  --body-option=--rename-proc-prefix=c2fbPorted_ \
  --header-compiler-option="-I$source_root/rtlib" \
  --header-compiler-option="-I$source_root/sfxlib" \
  --header-compiler-option="-I$source_root/sfxlib/linux" \
  --header-compiler-option="-I$source_root/sfxlib/unix" \
  --header-compiler-option=@fb_tools/c2fb/profiles/freebasic-linux-glibc-x86_64.rsp \
  --body-compiler-option="-I$source_root/rtlib" \
  --body-compiler-option="-I$source_root/sfxlib" \
  --body-compiler-option="-I$source_root/sfxlib/linux" \
  --body-compiler-option="-I$source_root/sfxlib/unix" \
  --body-compiler-option=@fb_tools/c2fb/profiles/freebasic-linux-glibc-x86_64-body.rsp
```
The Linux RTLIB host sweep also uses
[freebasic-rtlib-linux-x86_64-units.json](profiles/freebasic-rtlib-linux-x86_64-units.json).
It supplies crt/setjmp.bi for the jmp_buf users, includes the GPM and Linux
termios layouts for the two Linux console drivers, and routes file-scope device
callback tables through the body pass, where their function declarations are
available. This manifest adjusts per-source options only; select the C input
files with patterns matching the target RTLIB_SRC selection in FreeBASIC's
mk/rtlib-sources.mk.

Type mappings match exact C names. When a source uses both a record tag and a
typedef alias for that record, map each name to the same FreeBASIC type.
With the default `c2fb_` prefix, generic body conversion also matches C record
and typedef names to same-named generated FreeBASIC aliases when they are
available in the source directory. Record names also require a matching layout.
Explicit type maps remain available for renamed types or bindings generated
with another prefix.
Repeat `--rename=CName=FbName` to rename candidate procedures and external
bindings while preserving their C linker aliases. The output reports matched
and unused mappings; this can resolve FreeBASIC intrinsic name conflicts, for
example `--rename=fb_sfxMusicStatus=c2fb_sfxMusicStatus`.
Existing FreeBASIC `Declare` signatures with a trailing `...` can resolve C
body calls by their `Alias` name. C2FB applies the declared types to fixed
parameters and translates additional arguments from their C expressions.
Pass `--include-header-inline-bodies` to also consider inline definitions from
included headers as body candidates, even when the root C file does not call
them. Other static header helpers remain dependency-driven. When generating a
binding for the same headers, use `generic-header --no-inline-bodies` so simple
inline functions are not emitted both as macros and as function bodies. Body
conversion also reuses generated scalar typedef aliases in the source directory.
For unity builds that textually include `.c` files, pass
`--include-included-c-source-bodies` to treat those function definitions as
members of the same translation unit. The option enables preprocessor markers
so C2FB can distinguish included `.c` files from ordinary headers. Use it only
when the included files are not also compiled as separate translation units.
To translate function bodies defined directly in a header, pass that `.h` file
as the root input to `translate-simple-generic-c`; those definitions follow the
same candidate path as root `.c` functions.

Generic body conversion can lower relaxed `__atomic_load_n(pointer, 0)` reads
and `__atomic_store_n(pointer, value, 0)` writes when invoked with
`--assume-single-threaded-atomics`. This option is a semantic promise that no
other thread accesses the object; it supports integer scalar types only.
SQLite preprocessed conversion enables these lowerings automatically for
`THREADSAFE=0` and keeps them disabled for thread-safe builds.

For generic projects with thread-safe integer atomics and object-pointer
load/store/exchange/compare-exchange operations, pass `--atomic-mutex`.
C2FB preserves C11 load, store, exchange, fetch-add/sub/and/or/xor,
compare-exchange, and thread-fence operations by serializing them through
FBC's process-wide runtime lock. Compile the resulting FreeBASIC modules with
`-mt`. This gives stronger ordering than the requested C memory order. Every
access to those atomic objects must pass through C2FB's lowered operations,
since native C atomics do not use the FBC lock. `atomic_is_lock_free` returns
false in this mode. Atomic-flag test-and-set and clear are supported with an
explicit `--type-map=atomic_flag=UByte` when the target ABI uses one-byte flags.
Floating-point atomics, pointer fetch arithmetic/bitwise operations, signal
fences, and other atomic operations remain unsupported.

When a target ABI uses all-bits-zero storage for null pointers, a profile may
enable `--assume-zero-static-aggregates`. With that explicit promise, C2FB may
omit a file-scope aggregate initializer when every specified scalar value is
integer zero or a null pointer constant. FreeBASIC's static storage then
provides the same zero-initialized object. Nonzero or unresolved initializers
remain unsupported. The Linux glibc x86-64 body profile enables this for
glibc's `PTHREAD_MUTEX_INITIALIZER`.

```sh
build/c2fb translate-simple-generic-c source.c source_candidates.bas cc -Iinclude -DAPP_FEATURE=1 --type-map=WidgetHandle=WidgetHandle --fb-source-directory=fb_bindings
```

`translate-simple-generic-tree` scans preprocessed `.c` files.
`translate-simple-generic-tree-c` preprocesses each raw `.c` file in a directory
with one shared compiler configuration. Raw body conversion uses the C
preprocessor with `-E -x c` and retains source markers to separate root-file
definitions from included headers. It emits root-file bodies and only static
header helper bodies they call. Non-static inline header bodies need a
FreeBASIC declaration or a separate conversion. Repeat `-I` and `-D` as needed.
`@options.txt` response files are also accepted, with one argument per line. Pass
`--keep-unresolved` or `--include-existing` to retain callers with missing helper
bodies or include existing procedures. With `--keep-unresolved`, a referenced
same-file helper whose signature is supported but body is rejected also gets a
prototype, so the candidate can compile while the missing implementation stays
visible in its skip report. For example:

```sh
build/c2fb translate-simple-generic-tree-c src candidates cc -Iinclude -DAPP_FEATURE=1 --fb-source-directory=fb_bindings
```

When source files have different per-translation-unit flags, use the
compilation database runner instead of the shared tree configuration. After
building C2FB with `make -C fb_tools/c2fb converter`, run:

```sh
python3 fb_tools/c2fb/c2fb_compile_commands.py build/compile_commands.json fb_candidates --converter=../fb_tools/c2fb/build/c2fb --source-unit-context --jobs=4 --c2fb-option=--fb-source-directory=/absolute/path/to/fb_bindings
```

Pass `--jobs=N` to run up to N independent compiler entries concurrently
(1 to 32, default 1). Results are reported in database order; candidates and
type contexts remain staged until all selected entries succeed.

The runner reads each entry's working directory and compiler arguments, removes
compile and linker output options, and invokes C2FB separately for each distinct
`.c` source and flag set. C++ entries are skipped. Response files use shell-style
quoting. The output directory and path-like converter value are relative to the
database directory; compiler flags and C2FB options run from each entry's working
directory. Candidate files are staged and published only after every C2FB run
exits successfully. `compile-command-map.csv` maps each candidate back to its
source, working directory, compiler, and arguments. If a final rename fails,
the runner restores previous outputs and removes files already published by
that batch. C2FB uses the GCC/Clang
`-E -x c` interface; repeat `--c2fb-option` for common body-conversion options.

Add `--source-unit-context` to generate a separate type context for each C
translation unit. This runs the two-pass source-unit workflow with that entry's
compiler flags for both passes, records private record layouts and file-local
static objects, and includes the context from its candidate file. The context
and candidate are staged and published together. Use repeat `--header-option`
arguments for generic-header settings such as `--type-map`; `--c2fb-option`
continues to supply body settings. `--fb-source-directory` and
`--fb-source-recursive` passed through `--c2fb-option` select existing
FreeBASIC bindings for the per-unit overlay. Repeat
`--c2fb-option=--fb-source-pattern=GLOB` to filter those bindings, and add
`--c2fb-option=--fb-source-include-closure` to stage their local quoted include
dependencies and matching `.bas` owners. These source-index options require
`--source-unit-context`. Pass repeat `--body-compiler-option` arguments for
defines or include paths needed only while converting bodies; the map records
these options. `--source-body-compiler-option=SOURCE_PATTERN=OPTION` applies an
additional compiler option only to matching source paths during body
preprocessing. Patterns may match the absolute source path or a source-relative
suffix, and the selected options are included in that candidate's signature
and command-map row. Header preprocessing and unrelated source units keep their
original compiler flags. The map also includes the generated context filename
and whether source-unit mode was selected.
`--source-c2fb-option=SOURCE_PATTERN=OPTION` applies a C2FB body option only to
matching source paths. It uses the same path matching rules and records the
effective option in that candidate's signature and command-map row.

Raw body modes also accept repeat `--replacement-file=Rules.rpl` options. The
files use fbfrog's `convert c:` / `to c:` or `to fb:` pairs. C patterns are
matched as complete expressions or simple statements by tokens, so whitespace
and comments do not matter. `to c:` replacements pass through C2FB's normal
parser. `to fb:` replacements can provide one FreeBASIC expression or simple
statement, an indented block at a C statement boundary, or a complete function
override. A full-function override must contain one FreeBASIC `Function` or
`Sub` block with the source procedure's name and return kind. C2FB keeps the C
signature and linkage, and rewrites supported parameter names in the supplied
body. Multi-line replacements are inserted as authored, so review their
declarations and control flow with the generated candidate. A C `return`
replacement must end with a FreeBASIC `Return` and preserve whether it returns a
value. For example:

```text
convert c: widget_state(ctx)
to fb: WidgetState(ctx)

convert c: release_widget(w);
to fb: FreeWidget(w)
```

Use `to fb:` only when the replacement code already has the needed FreeBASIC
types and calling behavior. The rule is an explicit override for that complete
expression or statement, not a partial AST rewrite.
The generic mode emits FreeBASIC aliases for C's integer and size types and
includes `crt/longdouble.bi` only when the generated declarations or accepted
body candidates use C `long double`. C typedefs found in the
preprocessed input and declarations in the optional FreeBASIC source directory
can supply project-specific types and call signatures. Simple FreeBASIC scalar
and pointer aliases are followed when resolving those mappings. Unknown pointers
remain opaque `Any Ptr`; unknown by-value types are rejected. When no mapped
layout exists, body conversion can generate a private type for a complete,
unambiguous, unpacked C struct with supported scalar or pointer members, fixed
one-dimensional arrays, and known nested layouts. Other record field access
still requires a matching FreeBASIC layout. Pointer-only aliases for incomplete
generated records remain available for pass-through casts and storage; C2FB skips
member access until the record layout can be verified. Generic body conversion
resolves enum constants when their integral values are known from the supported
constant expression subset; other enum expressions remain unsupported. Keep
the C preprocessor and FreeBASIC compiler on the same target because `long`,
`size_t`, and `wchar_t` widths vary.
When a candidate calls a C math runtime procedure whose FreeBASIC CRT name uses
a trailing underscore, C2FB includes `crt/math.bi` unless an indexed binding
already declares that procedure.
GCC's `__builtin_huge_val`, `__builtin_inf`, `__builtin_huge_valf`, and
`__builtin_inff` lower to the matching positive-infinity CRT constants.
Automatic storage is declared at the procedure entry, with initialization left
at its C statement. This supports jumps across scalar declaration sites without
introducing BASIC scope-entry restrictions. Pre-name `__attribute__` and
`__declspec` groups are skipped when reading function declarations.
Mapped automatic record variables are accepted when their C layout is in the
fixed-size catalog. Mapped structs support positional and simple member-
designated initializers, plus assignment from a compatible struct compound
literal. When designators change field order, expressions with side effects are
rejected to preserve C evaluation behavior. Unknown or variable-length
aggregate locals remain rejected. Assignments from one-dimensional array
compound literals to compatible pointers use procedure-local storage, with
inferred or constant bounds, positional initializers, and one-dimensional
constant-index designators. Sparse elements are zero-initialized. When a later
initializer overrides an earlier initializer for the same index, only the last
initializer is emitted, preserving C compiler behavior for side effects.
Record-element member designators are supported. Consecutive member
designators for one element are merged in source order when they select
distinct fields. Adjacent designators for the same member path retain only the
last initializer, even if the earlier expression has side effects. Nested
field overrides are also merged when their values contain no identifiers.
Other repeated-field expressions, nonconsecutive member initializers, and
multi-level array index designators remain unsupported.
`sizeof(struct Tag)` and `sizeof(union Tag)` resolve tags from the current C
record bindings when C2FB emits their private record layouts.
Generic body conversion also queries the selected C compiler's predefined
macros for target widths such as pointer and `long` size. This works when the
body pass reuses a port-owned FreeBASIC record whose name differs from the C
tag. If a preprocessor cannot provide a macro table, ordinary body conversion
continues and only expressions requiring an unknown target size are skipped.
Address-of struct compound literals also use procedure-local record storage.
Their initializer prelude follows conditional and short-circuit evaluation, so
an unselected branch does not initialize its literal.
One-dimensional array compound literals in value expressions decay to typed
element pointers backed by procedure-local arrays, with the same branch-aware
initializer sequencing. Indexed designators preserve initializer-list order,
and duplicate whole-element indices retain only their final initializer.
Consecutive member designators for one record element are merged. Repeated
member paths retain their last initializer when adjacent. Nested field
overrides can be merged when their values contain no identifiers. Other
duplicate field expressions and interleaved member initializers are rejected
when their subobjects cannot be merged while preserving initializer order.
`sizeof` supports explicit bounds and inferred bounds from positional or
constant-index designated initializers, without translating or evaluating the
initializer expressions.
Rejection diagnostics include the owning C function and the unsupported
signature or statement so batch repair can be prioritized. For failures nested
inside an `if`, `for`, or block, the converter also reports the failing
condition, initializer, increment, or nearest statement text. Failed expression
and assignment parses report the byte offset where parsing stopped and the
remaining source text, which makes grouped repairs easier to target.
When assignment storage cannot be captured or converted, the diagnostic also
reports the C value type, FreeBASIC storage type, lvalue/const state, and bit
width.

One-dimensional automatic arrays with bounded integer constant expressions
are supported. Bounds can use integer literals, parentheses, unary signs, and
the `+`, `-`, `*`, `/`, `%`, `<<`, and `>>` operators. Constant `sizeof` and
`__builtin_offsetof` expressions on mapped records are also supported. Brace
initializers retain element order and zero omitted elements. Clearing occurs at
the declaration site, including repeated loop iterations. `sizeof` retains the
complete array size while ordinary use decays to a pointer. Fixed one-dimensional
automatic arrays of mapped records accept known enum constant bounds and
positional nested record aggregate initializers. Omitted fields and array
elements are zero-initialized at the declaration site.
For a single local declarator, C2FB locates the top-level initializer `=` before
tokenizing the declarator. Large brace initializers therefore do not consume the
bounded type-token buffer; local tables with hundreds of values can be translated
without raising that limit for unrelated type parsing. A regression exercises
126-element automatic and 406-element static arrays on native and GCC backends.
Member access and `sizeof` preserve the complete array extent; runtime-bound
record arrays remain unsupported. When C takes the address of a local array
and passes it to a void pointer parameter, C2FB uses the array's first-element
address. Other pointer-to-array contexts remain unsupported. For body
expressions, `__builtin_offsetof` also accepts a one-dimensional array member
designator with literal index `[0]`. Element zero shares the array member's
starting address, so it lowers to `OffsetOf(record, array(0))`; other indexes
remain unsupported. Generic body translation uses the generated tail accessor
for direct reads, writes, and
`__builtin_offsetof` on omitted flexible byte-array members. One-dimensional and
multidimensional VLAs with non-const scalar or pointer elements use managed
FreeBASIC arrays. C2FB captures each bound at the declaration point. Bounds use
sequenced integer-expression lowering in declarator order, preserving supported
side effects at the declaration site. Fixed-bound
automatic multidimensional arrays with scalar or pointer elements flatten into
row-major storage; chained indexes and `sizeof` for the whole array and its rows
retain their C shape. Initializer lowering follows C's flattened cursor across
brace elision: an explicit group initializes the next subaggregate at its
boundary, and braces around a scalar initialize the next leaf element. Scalar
and nested groups can therefore be interleaved while preserving row-major
placement and zero-filling omitted elements. Record-array element braces retain
their aggregate shape. Const-qualified automatic multidimensional arrays are
supported with initialized fixed bounds and with uninitialized fixed or runtime
bounds. The generated body keeps their storage read-only through C2FB's
expression model. Non-const automatic arrays with fixed bounds and positional
initializers can exceed the 65,535-element inline limit and use managed storage
up to the 262,144-element initializer cap. Each brace level retains the
converter's bounded 512-item list limit. Larger uninitialized fixed local
arrays also use managed storage.
SQLite body conversion also retains fixed one-dimensional array typedefs:
parameters of those typedefs decay to pointers to their element type, and
`sizeof(typedef_name)` uses the complete array extent. Variable-length and
multidimensional array typedefs remain outside this body subset.
Generic body expressions also support `sizeof(T[N])` and `sizeof(T[N][M])`
when the element type is recognized and every bound is a positive constant.
This covers array sizes embedded in expanded system macros such as Linux
`ioctl` request codes.
Local names are visible while C initializers are translated, which supports
self-size forms such as `Record *p = allocate(sizeof(*p))` when the record's
layout is known.
For `os_win.c` and `mutex_w32.c` body scans, a source-scoped ABI map resolves
common Windows SDK widths and pointer aliases such as `DWORD`, `BOOL`, `WCHAR`,
`HANDLE`, and `LPCWSTR`. A C record map can bind `win_syscall` to the
`WinSystemCallEntry` layout in `fb_src/sqlite3_os_win_types.bi`. For an
explicitly renamed file-local array declared after its record, C2FB retains the
initializer element count and lowers `sizeof(array)/sizeof(array[0])` to that
count. This converts the three Windows syscall-table callbacks from a
preprocessed `os_win.c`; their focused candidate object compiles. The full
candidate translator preserves typed indirect calls, including direct
file-scope callback objects. Accepted automatic local function-pointer
initializers keep their assignments at the C declaration site;
untyped call-through expressions remain outside the supported subset. The
FreeBASIC Windows port routes its API calls through a separate typed dispatch
layer. With Cygwin preprocessing and the same syscall
record map, C2FB also emits `winSimplifyName` and `mkFullPathname`; their focused
candidate object compiles. Those helpers and the related path-conversion,
temporary-directory, and symlink-resolution paths are now integrated behind the
FreeBASIC Cygwin target guard. FBC generated C for that target; producing an
object still requires the unavailable `cygwin-gcc` toolchain.
C record members also retain literal array bounds for primitive/pointer element
sizes, including unevaluated indexes; aggregate sizes remain unverified.
Preprocessed record bounds are captured from the original declarator text, so
multi-digit literals and parenthesized constant arithmetic are not split into
single-character tokens. Bounds outside the supported integer expression set
and multidimensional members remain rejected.
`sizeof` also accepts fixed arrays of record elements when the element record
has an explicitly known extent.
The explicit size set includes fixed `AuthContext`, `TableLock`, `SrcItem`,
`IndexedExpr`, `IndexIterator`, and `IndexListTerm` records; public
`sqlite3_index_info`, constraint, order-by, and constraint-usage records; and
the default-profile `WhereLevel`, `WhereLoop`, `WherePath`, and
`WhereRightJoin` records. For
`__builtin_offsetof`, a mapped non-array member uses the FreeBASIC `OffsetOf`
intrinsic. The `Parse` map uses `SqliteParseContext`'s size and field offsets
for nested-parser tail buffers; this follows the port-owned record layout and
does not claim that the full C and FreeBASIC records have ABI-identical sizes.
A trailing flexible array with a mapped
record element, or a pointer element with a known pointer-sized layout, uses
the one-element-placeholder size adjustment. The SQLite profile includes the
private `HiddenIndexInfo.aRhs` pointer tail used by virtual-table planning.
These paths rely on the declared port layout and do not compare its byte
offsets against C at runtime.

Selected pointer and structure expressions use types already defined in
`fb_src/`. The layout reader distinguishes fixed-array members from pointers
so each uses FreeBASIC's required parentheses or brackets. Layout metadata
supports nested member navigation and array decay; it does not establish C
structure sizes or fill missing port fields. Simple FreeBASIC `Type Alias As
Record` declarations are followed when matching C fields and selecting the
header that provides their layout.
The SQLite body path maps the shared `sqlite3CtypeMap` and
`sqlite3UpperToLower` lookups to tables in `sqlite3_global_data.bi`. The C
`sqlite3StrBINARY` address maps to a single storage accessor because C compares
that collation name by pointer identity in addition to comparing its contents.
The built-in window function name arrays likewise map to shared accessors so
registration and translated VDBE code preserve SQLite's pointer-identity
checks. `noopStepFunc` maps to an accessor returning the registered callback
address. The `WindowCodeArg.end` field maps to the FreeBASIC-safe `ending`
member in `SqliteWindowCodeContext`.
The sorter C records map to shared fixed layouts, including a one-element
placeholder for `VdbeSorter.aTask`; flexible-tail offsets subtract that
placeholder. Named callback typedef signatures remain available for record
fields such as `SortSubtask.xCompare`, while the local `SorterCompare` alias is
treated as opaque during pass-through assignments.
The dbstat page, cell, table, and cursor records map to the fixed layouts in
`sqlite3_dbstat_types.bi`, including the 32-page cursor stack.
Selected `sqlite3Config` reads lower through dedicated getters; the
`sharedCacheEnabled` field uses `sqlite3ConfigSharedCacheEnabled()`. Writes to
that setting use the explicit `sqlite3_enable_shared_cache()` setter. Reads of
`sqlite3Config.pcache2` use a read-only copy from
`c2fbSqlitePcacheMethodsSnapshot()` because the port stores that table
separately; updates continue through `sqlite3ConfigSetPcacheMethods()`.

Some C field names differ only by case. FreeBASIC identifiers are
case-insensitive, so the `DateTime.M` and `DateTime.m` members use the
FreeBASIC names `month` and `minute`; the record reader translates those field
references while retaining the original C names in its record catalog.

The C record catalog reads the selected C declarations, including nested
structs and unions, and retains their member types separately from the BASIC
layouts. Opaque BASIC pointer fields gain typed `CPtr` reads from those C
declarations. Assignments and addresses still refer to the original field
storage. For nested access, a typed C pointer stored in an `Any Ptr` field is
cast from the actual field storage before dereferencing. C member arithmetic
retains the declared scalar widths and signedness;
matching field paths establish names for nested records without synthesizing
missing fields.
Field lookup preserves an exact C record owner before following a typedef, so
a tag such as `Walker` remains the record-catalog key when its FreeBASIC layout
is named `SqliteWalker`.
The debug-only `TreeView` record maps to `SqliteTreeView` in
`sqlite3_treeview_types.bi`, including its fixed 100-byte branch array.
The private `sqlite3` connection record keeps its exact same-name field owner.
C2FB uses the port's `SizeOf(sqlite3)` for its own connection allocation; this
does not claim that the private C and FreeBASIC connection layouts match.
The private `aHardLimit` array in `main.c` maps to
`sqlite3LimitHardValueTable()`, the same hard-limit data used by the port's
`sqlite3_limit()` implementation; the generated limit body compiles.
When an opaque `Any Ptr` field represents a C pointer-to-pointer, indexed
lvalues preserve the remaining pointer depth so stores target pointer-sized
elements.
The layout catalog maps `sqlite3_index_info` and SQLite's appended hidden
planner record through `sqlite3_vtab_types.bi` so their C field accesses retain
the declared FreeBASIC storage types.
The local `CCurHint` stack record in `wherecode.c` maps to
`SqliteCursorHint` in `sqlite3_walker.bi`; this lets the loose body converter
translate the cursor-hint callbacks and builder when
`SQLITE_ENABLE_CURSOR_HINTS` is enabled.
`DbFixer` maps to the FreeBASIC record that embeds `SqliteWalker`, and `Token`
maps to the parser's borrowed token layout. These mappings let the translator
emit schema-fixer callbacks without treating their record members as opaque.
`AuthContext` maps to the parser-owned record that saves and restores
`Parse.zAuthContext`.
`Parse` and `sqlite3InitInfo` map the parser context and its initialization
bitfields, including the separately stored `checkSchema` and packed
`orphanTrigger`, `imposterTable`, and `reopenMemdb` values stored in
`SqliteDbInitInfo.flags`.
`InitData` maps to the fixed stack context shared by schema initialization and
its row callback.
`Db` maps to the fixed `SqliteDbSlot` record, and the port stores the full
`sqlite3.aDb` capacity inline. C2FB can therefore translate `sizeof` of a
database slot; ATTACH uses the already reserved slot instead of reallocating
the C pointer array.
`SubrtnSig` maps to `SqliteSubroutineSignature` in `sqlite3_vdbe_core.bi`; this
lets body conversion type its fields and `sizeof(pSig[0])` allocation.
`NameContext` maps to `SqliteNameContext`, including its pointer-sized union
and the SELECT/source-list context needed by expression resolution.
`RenameCtx` maps to the fixed five-field `SqliteRenameContext` stored in
`sqlite3_parser_types.bi`; its field mapping and fixed extent support the ALTER
column and table rename callbacks.
`Returning` maps to `SqliteReturning`, which embeds the mapped Trigger and
TriggerStep records and the fixed 40-byte trigger name. Its fixed extent lets
C2FB translate cleanup and allocation sizing for SQL `RETURNING` clauses; the
`sqlite3_snprintf` call in trigger setup still needs a manually reviewed body.
`AggInfo`, `AggInfo_col`, and `AggInfo_func` map to the fixed aggregate
analysis records in `sqlite3_agginfo_types.bi`.
`RefSrcList` and `CheckOnCtx` map to the fixed Walker callback contexts in
`sqlite3_walk_contexts.bi`.
`IdxCover` maps to the two-field `SqliteIdxCover` record stored through the
Walker union during expression-index coverage checks. Its fixed local extent
lets C2FB retain the field types and automatic storage for this context.
The catalog also maps `IdList`, `Subquery`, `Upsert`, `FKey`, `Trigger`,
`TriggerStep`, and `DbClientData` to the corresponding FreeBASIC records,
including FKey's trailing column-map array and the client-data name offset.
These mappings support field access and cleanup conversion; they do not
validate aggregate `sizeof` for variable-length records.
`BtreePayload` maps to `SqliteBtreePayload`, and the `sqlite3PendingByte`
global retains its exported C integer storage. These mappings let B-tree cell
writers and auto-vacuum arithmetic keep their source field and global types.
`UnpackedRecord` maps to `sqlite3VdbeUnpackedRecord` for fixed-layout local
records and index comparison.
`IndexSample`, `StatSample`, `StatAccum`, and `ValueNewStat4Ctx` map to the
STAT4 records in `sqlite3_schema_types.bi`, `sqlite3_stat4_types.bi`, and
`sqlite3_vdbe_mem_types.bi`; their optional fields follow
`SQLITE_ENABLE_STAT4` in both source profiles.
`VdbeFrame` maps to the fixed nested-program frame in `sqlite3_vdbe_core.bi`;
its array storage follows the frame and is not part of the record.
`ScanStatus` maps to the feature-gated `SqliteScanStatus` layout in
`sqlite3_vdbe_core.bi`. `PreUpdate` maps to the callback/API state record in
`sqlite3_preupdate_types.bi`, including its nested inline key-info storage.
The pre-update type preserves the fields read by these bodies; the
one-element FreeBASIC key-info tail is not treated as a verified C-size match.
`DblquoteStr` maps to the fixed header and eight-byte allocation placeholder
used by normalized SQL's double-quoted string tracking. The add/search routines
and VDBE deletion cleanup are guarded by `SQLITE_ENABLE_NORMALIZE`.
`IntegrityCk` maps to the private `SqliteIntegrityCk` context for B-tree
integrity traversal; its local `sizeof` uses the FreeBASIC record that embeds
the port's extended string accumulator.
`With` and `Cte` map to the CTE layout in `sqlite3_walker.bi`. The CTE element
size is verified, and C2FB lowers the trailing-array expression
`offsetof(With,a)+sizeof(Cte)` through the one-element `SqliteWith` placeholder
without treating the whole variable-length record as fixed-size.
`Window` maps to the complete `SqliteWalkerWindow` layout. The private
`CallCount`, `NthValueCtx`, `NtileCtx`, and `LastValueCtx` records map to the
fixed callback-state layouts in `sqlite3_window_state.bi`.
`WindowRewrite` maps to the complete five-pointer `SqliteWindowRewriteContext`
in `sqlite3_walk_contexts.bi`; its fixed extent is verified so aggregate
`sizeof` and Walker callback field access use the same C layout.
`WindowUpdate` maps to the four-field `SqliteWindowUpdateRule` record used by
the local built-in frame table. C2FB still rejects that function's initialized
array of records, so `sqlite3WindowUpdate()` is ported manually. It also skips
`sqlite3WindowFunctions()` because its initializer builds a `FuncDef` table;
that registration table and its two `row_number` callbacks are ported manually.
`FuncDestructor` maps to the fixed callback, reference-count, and user-data
record used by application-defined function registration.
`PragmaName`, `PragmaVtab`, and `PragmaVtabCursor` map to the generated pragma
metadata and cursor layouts in `sqlite3_pragma_types.bi`; the cursor base
record maps from `sqlite3_vtab_cursor`.
`JsonParent`, `JsonEachCursor`, and `JsonEachConnection` map to the JSONB
iterator and virtual-table layouts in `sqlite3_json_vtab_types.bi`. The cursor
reuses the mapped `JsonParse`, `JsonString`, and `sqlite3_vtab_cursor` records.
`PgHdr1`, `PCache1`, `PGroup`, `PgFreeslot`, and `PCacheGlobal` map to the
source-layout records in `sqlite3_pcache1_types.bi` so pcache1 hash and LRU
procedures can be translated with typed field access. The FreeBASIC PCache
wrapper dispatches through a copied PCACHE2 callback table and installs PCache1
as the built-in default implementation.
`StrAccum` maps to the shared prefix of the port's `sqlite3_str` record for
field access. The FreeBASIC record has appended formatter state, so C2FB does
not use it as a source `StrAccum` size. The SQLite `GroupConcatCtx` adapter is
an explicit port-layout substitution: it maps the source fields to
`SqliteGroupConcatContext` and uses that context's size for generated FreeBASIC
bodies. It does not claim C ABI compatibility for that aggregate record.
The private `sqlite3_backup` record in `src/backup.c` maps to
`SqliteBackupContext` so the converter can translate backup-state field access.
The memory VFS `MemStore`, `MemFile`, and `MemFS` records map to the internal
layouts in `sqlite3_memdb_types.bi`; `sqlite3Config.mxMemdbSize` maps to the
port's configured memory-database maximum accessor. These mappings let one
loose C2FB batch emit `sqlite3_serialize()` and `sqlite3_deserialize()`.
The optional MEMSYS3 allocator uses explicit `Mem3Global` and nested
`Mem3Block` mappings from `sqlite3_memsys3_types.bi`. Its eight-byte block
union, pool pointer, and fixed small/hash lists retain their source indexing
structure in translated allocator bodies.
The optional dbpage virtual table maps `DbpageTable` and `DbpageCursor` to the
records in `sqlite3_dbpage_types.bi`, which lets the converter translate its
cursor, pager, and update callbacks together.
The optional OSKV decoder maps its private 256-byte signed hex table to the
stable `sqlite3KvHexValueTablePtr()` accessor so the translated decoder can
retain nested C pointer indexing without copying the table into each caller.
Aggregate `sizeof` remains restricted to layouts listed as fixed for the
selected source profile. These include `sqlite3_index_info`, the fixed `Select`,
`Table`, `Db`, `Cte`, `Index`, `WhereTerm`, `WhereClause`, `WhereOrCost`, `WhereOrSet`,
`WhereOrInfo`, `WhereAndInfo`, and `WhereLoopBuilder` records, the `WhereLoop.u`
union, `NameContext`, `AggInfo` and its entries, `Window` and its callback
contexts, `Trigger` and `TriggerStep`, `PragmaName` and the pragma virtual-table
records, the JSON parent and cursor records, the `RenameCtx`, `RefSrcList` and
`CheckOnCtx` walker contexts, and the B-tree-specific
`CellArray`, which has six fixed cell stages. The `Index`, `WhereClause`, and
`WhereLoopBuilder` extents follow the default profile; `SQLITE_ENABLE_STAT4`
and `SQLITE_SMALL_STACK` need their own layout checks.

The expression parser in `c2fb_expr.bi` preserves C precedence and associativity
with explicit grouping. Comparisons and logical operators produce C's integer
values 0 and 1 inside arithmetic, assignments, returns, and call arguments.
`&&`, `||`, and nested `?:` retain conditional evaluation. Declared scalar types
select integer division or floating division, preserve integer promotions and
mixed signed/unsigned operations, and make literal suffixes explicit. Known
floating-to-integer conversions use `Fix` before conversion to preserve C's
truncation toward zero, including assignments and returns.

`c2fb_sequence.bi` lowers assignment values, compound assignment values,
prefix/postfix increments, and comma operators to statements and procedure-local
temporaries. Updated indirect storage is addressed once, including indexed
lvalues and pointer increments. Assignment associates right to left and comma
evaluation stays ordered. Known record copies retain the port's existing record
types. If a C member's expression type differs from its FreeBASIC field storage
type, the converter casts to the C type for the operation, then casts back for
the write and converts the stored value when it is read. Typed callback fields
use local aliases to address callback storage. Assignment lowering freezes the
converted right-hand value before the storage write, so calls and other
side-effects on the right are evaluated once.
Side effects in `&&`, `||`, and `?:` remain inside the selected branch.
Loop conditions run their effects on every test, including
after `continue`. Casts to `void` evaluate and discard their operands.

Pointer-to-pointer indexing keeps a leading pointee `const` on the resulting
pointer type without treating the pointer slot itself as read-only. When the
port stores that slot using a different FreeBASIC field type, address capture
casts to the field's declared storage type before a write. Full per-level
qualifier tracking for more complex C pointer declarators remains unsupported.
If a body field has a concrete FreeBASIC storage type but no resolved C type,
pointer indexing leaves the field expression typed by its declared storage
instead of emitting an empty `CPtr` cast. The FTS5 index source-unit regression
checks that generated candidates contain no `CPtr(,)` and compile.
For a single pointer, a trailing top-level `const` no longer makes the pointed-
to data read-only. Unary dereference also keeps a pointer slot writable for
`const T **`, while a single pointer to const data remains read-only.
Pointer differences between compatible typed pointers also normalize pointee
`const` and retain C's element-count result; opaque `void *` differences remain
unsupported because their element size is unknown.

Call arguments that require statements are materialized before the call in one
allowed C evaluation order. This avoids depending on FreeBASIC's ABI-specific
argument loading order. The converter does not validate unsequenced C side
effects; the input must already have defined C behavior. Typed C pointer results
also receive `CPtr` conversions when the port's ABI declarations return `Any Ptr`.
Call arguments use the FreeBASIC declaration's parameter types when one is
available, then add explicit pointer casts where the C source and port ABI use
different pointer types. `const void *` retains its `Const Any Ptr` parameter
type so explicit C casts and callback declarations agree.

`sqlite3VdbeExplain` calls lower through fixed adapters for no extra
arguments, one integer or string argument, one string followed by an integer,
an integer followed by a string, and two or three string arguments. Optional
statement-scanstatus accounting remains outside this adapter.

For C implementation bodies, the converter also accepts a trailing `...`
parameter, stores `va_list` as `Cva_List`, declares it `ByVal` to preserve C's
va_list parameter ABI, and lowers
preprocessed `va_start` and `va_end` builtins to `Cva_Start` and `Cva_End`.
Typed `va_arg` builtins lower to `Cva_Arg` when the requested type is supported.
Opaque object pointers
can be declared as local `Any Ptr` values; field access still requires a mapped
C record. These additions let variadic bodies reach statement and layout
diagnostics that were previously hidden by the function signature.

C11 and C23 `_Generic` selections are supported when C2FB can resolve the
controlling expression and association types. The converter emits only the
matching association, or `default` when no type matches, so expressions in
unselected arms are not evaluated. Ambiguous or unsupported types remain
rejected. This covers glibc's C23 `wcsstr` macro, which selects a
const-preserving result type from its input pointer.

GCC's `__builtin_bswap16`, `__builtin_bswap32`, and `__builtin_bswap64`
calls lower to width-specific mask-and-shift expressions. C2FB materializes the
operand once before reusing it for each output byte, and keeps the C width
without relying on host byte order.

GCC's `__builtin_expect` and `__builtin_expect_with_probability` lower through
private helpers with C `long` results. The helpers evaluate each operand once,
including operands with side effects, then discard the branch hint because
FreeBASIC has no matching probability annotation.

C11 `_Alignof` and GNU `__alignof__` lower through a generated record whose
field offset exposes the FreeBASIC type's target alignment. This requires the
mapped type to preserve the C ABI layout. The x86-64 body translator also
supports `__builtin_cpu_supports` for `avx`, `avx2`, `avx512f`, `avx512bw`,
`pclmul`, and `vpclmulqdq`; its generated helper checks CPUID bits and the
OS-enabled vector state. On other targets, that helper returns false.

The C symbol catalog resolves simple typedef chains and records procedure
return and parameter types. This makes declared integer call results usable in
division and casts, and preserves known floating-to-integer call conversions.
Record typedefs retain their tagged C layout mapping in body type resolution,
so nested member access through typedef-typed fields stays typed.
Compiler attributes are stripped before C procedure signatures are indexed, so
attributes such as `SQLITE_NOINLINE` do not hide otherwise callable helpers.
Definitions in the same input file are callable, including recursive private
helpers and forward definitions. A dependency pass removes callers whose
required local helper was not translated. Generated prototypes precede the
bodies. Supported C runtime memory, string, math, and `printf` procedures use explicit
`CDecl Alias` bindings when their declarations occur in the input, avoiding
accidental selection of BASIC intrinsics.

Callback parameters, typedefs, members, and file-scope function-pointer objects
retain their supported calling conventions. Variadic callback signatures with
at least one fixed argument are supported under `CDecl`. Calls through
variadic callbacks and direct variadic procedures retain conversions for fixed
parameters and apply C's default promotions to trailing scalar arguments,
including narrow integers to `int` and `float` to `double`. Variadic calls
with unsupported trailing aggregate or unknown types remain rejected. Function
names decay through `ProcPtr`, and typed indirect calls preserve argument
conversions and results. Callback casts and destructor sentinel comparisons
use explicit pointer conversions. Missing signatures, calls with too few
fixed arguments, and incorrect nonvariadic argument counts remain rejected. A
known nonvariadic callback result can be invoked
again directly, as in `factory(value)(value + 1)`, with each call resolved from
its own callback signature. Functions that return known callback chains also
translate; a returned C function designator becomes its corresponding `ProcPtr`.
Callback aliases retain resolved object-pointer types such as `sqlite3 Ptr`;
unresolved object pointers still use `Any Ptr`. This keeps known callback table
entries compatible with their declared C procedures.
Unary dereferences of known callback pointers retain their function-designator
type, so C forms such as `(*image->f.destroy_image)(image)` call the typed
FreeBASIC callback directly.
File-scope callbacks written as direct C declarators, such as
`int (*callback)(int)`, now emit a typed external object
and can be called from a candidate body. Calls hidden inside preprocessor-
expanded function-pointer casts still need manual lowering.
Declaration tokenization accepts up to 256 tokens so callback-heavy function
signatures are not cut off before their final closing parenthesis; the previous
96-token bound rejected `createFunctionApi` despite its callback types being
supported.
Inline C callback signatures used by a candidate receive named local FreeBASIC
procedure-pointer aliases. Those aliases let generated code cast an opaque
`Any Ptr` field to a callback type before assignment or invocation. Local C
callback declarations use the matching alias. Static callback scalars are
zero-initialized when C leaves them uninitialized; explicit initializers are
accepted when they are C null pointer constants or function designators.
Runtime initializers remain unsupported. Function-type typedefs can reuse a
matching callback alias from the supplied FreeBASIC bindings after C2FB checks
the return and parameter types. This preserves the pointer depth needed to
index callback tables, including fixed-size static local tables initialized
with function designators and null entries. Local C `void *` variables use
opaque `Any Ptr` storage; operations that need a pointee type remain rejected.
Local static object pointers without initializers are zero-initialized, and
those with a C null pointer constant, a string literal, or the address of a
file-scope object retain their persistent storage. Runtime pointer
initializers remain unsupported.

Supported literals include bounded decimal, octal, and hexadecimal integers,
decimal floating constants, and ASCII character constants with standard,
octal, or hexadecimal escapes. ASCII `L'...'` character constants use the
target's `wchar_t` type. Adjacent C string literals are combined as bytes,
including embedded NULs, and use static literal storage rather than a temporary
BASIC string. Primitive/pointer `sizeof` queries and string-literal sizes remain
unevaluated, including calls, dereferences, and increments in their operands.
Known scalar casts use `Cast`; object-pointer casts use `CPtr`. C `char *`
indexing and dereferencing use byte pointers because FreeBASIC `ZString`
elements have string behavior. Parameters and locals receive generated names,
so C local names that differ only in case or match a FreeBASIC keyword remain distinct.

FreeBASIC's current expression optimizer can regroup floating additions and
accumulate constants across the emitted parentheses and same-type casts. Small
private value procedures retain the C operation boundaries and single/double
rounding. They may add call overhead with native code generation; they remain
part of the candidate until its numerical behavior and performance are reviewed.

Scalar static locals with constant initializers use procedure-local FreeBASIC
`Static` storage; uninitialized C statics use zero-initialized static storage.
Uninitialized fixed-size local static arrays retain that storage duration and
zero initialization as well. These arrays have a separate 524,288-element
limit, which admits common 256 KiB I/O buffers without expanding zero elements
into generated source. Mapped local C structs with known fixed layouts
can also use static storage without an initializer or with a recursive brace
initializer containing C constants, including simple member designators. An
omitted initializer is zero-filled. Fixed byte-array members accept brace or
narrow string initializers, with omitted elements zero-filled. A mutable local
static character array can infer its bound from a narrow string initializer;
its initial bytes are set once and later writes retain C's static storage
semantics.
Fixed local static arrays, including const-qualified arrays, with multiple
constant dimensions and brace initializers are flattened into `Static`
row-major storage; C row indexing retains its trailing-dimension stride.
Const-qualified static tables remain read-only, and record-array element
initializers preserve their nested fields.
Mapped local C unions can use zero initialization or initialize their first
member with a supported constant; designated members and array members remain
unsupported. Aggregates without a known mapped layout also remain unsupported.
File-scope static scalar and pointer objects use
private module storage, including supported constant initializers, so functions
from one C translation unit share that state without exporting a C symbol.
One-dimensional file-scope static arrays with supported element types and fixed
bounds, or bounds inferred from brace or narrow string initializers, use module
storage. Body expressions preserve their pointer decay and indexed element
access. Fixed multidimensional file-scope static arrays of supported scalar
elements with brace initializers are flattened into row-major module storage;
direct and chained indexing preserve C row decay and trailing-dimension strides.
One-dimensional file-scope `static` callback arrays with a supported signature
accept fixed bounds or bounds inferred from a brace initializer. Function
designators are checked against the callback signature, and null entries use
a context-typed `0` so included records can supply the callback type without
requiring a generated alias. Since FreeBASIC cannot const-qualify a
procedure-pointer alias, const callback arrays stay private to the generated
module and candidate writes to those slots are rejected.
When an initializer targets an existing FreeBASIC procedure, its declaring
header is included in the candidate module.
Multidimensional and non-static file-scope callback arrays remain manual.
Block-local static arrays of byte pointers with narrow string-literal
initializers, including simple C casts such as `(u8*)" "`, keep their pointer
table and storage lifetime; indexed reads lower to FreeBASIC array access.
Automatic C variable-length arrays with runtime integer bounds and scalar or
pointer elements use FreeBASIC dynamic arrays. Multidimensional VLA bounds are
lowered in declarator order, preserving supported side effects at the
declaration site. Uninitialized non-static fixed-bound automatic arrays with
scalar or pointer elements use dynamic storage above C2FB's 65,535-element
inline-array limit. Non-const fixed-bound automatic scalar and pointer arrays
with positional initializers also use managed storage through 262,144 elements.
Fixed-bound automatic multidimensional arrays with scalar or pointer
elements flatten into row-major storage. C2FB evaluates and stores a VLA bound at the
declaration point, so later changes to the source bound variable do not change
`sizeof(array)`. FreeBASIC allocates dynamic arrays on the heap while C allocates
automatic arrays on the stack; allocation pressure and failure behavior can
differ. Dynamic bounds must be positive and fit FreeBASIC's signed array range.
Initialized VLAs remain unsupported, as C forbids initializers for VLA objects.
Const-qualified automatic arrays with fixed or runtime bounds are supported;
their mutable FreeBASIC backing storage stays read-only through C2FB's body
expression model.
Modifications of known const storage,
non-ASCII or multibyte character constants, static aggregate locals outside
the mapped struct and first-member union subsets and static pointer initializers
outside the supported forms described above,
untyped function-pointer calls, unsupported types, switches with unsupported
case expressions or control flow, and preprocessor-controlled function bodies.
Division and scalar casts are rejected
when their operand types are unknown, including undeclared call results and
structure fields. Hexadecimal floating constants, by-value long-double record
fields whose target alignment cannot be represented, unsupported
array-bound operators and VLA bound expressions outside the supported syntax,
structure inference beyond supported scalar/pointer fields, fixed
one-dimensional arrays, and known nested layouts, plus implicit conversions
through unknown types, still require manual work. Reads from
SQLite's nested `fg` bitfield records use masked reads from a `flags` word in
the corresponding FreeBASIC layout. Unsigned bitfield assignments, including
fields packed into a shared storage word, use width masks and explicit storage
reads and writes.
The SQLite-specific layout map also maps `sqlite3InitInfo` bitfields onto
`SqliteDbInitInfo.flags`, preserving their C offsets during reads and writes.
Generic body translation reads signed bitfields with width-aware sign
extension and truncates signed assignments and compound assignments to their
declared width for fields up to 32 bits. Pre/post increment and decrement use
the same width rules and preserve neighboring fields in mapped packed storage.
For generic layouts, the body catalog recognizes FreeBASIC's named bitfield
syntax while taking width and signedness from the C declaration. Assignments
capture the containing record because FreeBASIC cannot take the address of a
bitfield itself.
SQLite's default `Bitmask` typedef maps to `sqlite3_uint64`. The five
`VdbeCursor` boolean bitfields map to the shared `cursorFlags` storage word,
using offsets read from the C record declaration.
Fixed-size static arrays with constant brace or string initializers are emitted
as FreeBASIC static arrays so their storage lifetime is preserved. Block-local
tagged records are indexed alongside file-scope records. When a local record
maps to an existing FreeBASIC layout, C2FB can translate a fixed static array
of those records, including constant pointer and scalar fields.
Static `wchar_t` arrays with `L`-prefixed string initializers are lowered to
target code units when the mapped FreeBASIC scalar has the same width as the C
target. UTF-8 source characters and `\u`/`\U` escapes are decoded, including
surrogate pairs for 16-bit `wchar_t`; unsupported encodings and width mismatches
remain explicit skips.
File-scope body layouts can also generate private `Type` and `Union` records
when fields are supported scalars or pointers, fixed one-dimensional arrays,
or nested records with known size and layout. This includes a fixed array of
union elements; packed, volatile, bitfield, and unknown-size layouts remain
manual.

The selected `aPragmaName`, `pragCName`, and `sqlite3StdType` globals map
through stable FreeBASIC accessors. `pragCName` points to the generated column
label table used by both the main PRAGMA dispatcher and its virtual tables.
Their original C array extents are retained for `sizeof` and their element
access remains pointer-indexed. Pointer-to-integer casts use the native pointer
width before applying the requested C integer width; this matches SQLite's
callback argument convention on the configured host.
The read-only `sqlite3OpcodeProperty` array maps to the table generated in
`sqlite3_opcodes.bi`.

Body candidates whose signature or body uses the C `volatile` qualifier are
rejected because current FreeBASIC lowering cannot preserve volatile load/store
semantics. Source-record generation also excludes structs with volatile
members.
It recognizes SQLite's expanded `(void)(name)` unused-parameter form, including
comma-separated chains, only when each operand is a bare identifier.
It also drops nested `(void)0` expansions used for disabled C assertions.
Passing the FreeBASIC source directory skips functions that already have a
body and restricts calls to declarations available to the port:

```sh
fb_tools/c2fb/build/c2fb translate-simple src/util.c \
  /tmp/sqlite3_util_candidates.bas fb_src
fbc -d SQLITE_THREADSAFE=1 -i fb_src -c /tmp/sqlite3_util_candidates.bas
```

When the FreeBASIC source directory is supplied, calls may target `.bi`
declarations, exported procedures that already have FreeBASIC bodies, or
supported definitions in the current C file. The
converter excludes `Private` and `Static` procedures from cross-module calls.
An existing private port body can be emitted again as a private helper when
the generated module needs its local definition.
Candidate files include generated prototypes only when the existing `.bi` files
do not already declare them, and include the owning typed headers for calls and
`ProcPtr` references they use. This avoids duplicate declarations and missing
callback declarations. Standalone C calls use current FreeBASIC call syntax.
SQLite's generated `sqlite3_api_declarations.bi` and
`sqlite3_internal_api_declarations.bi` are fallback call catalogs. When a
module has a more specific declaration for the same C alias, C2FB uses that
typed signature instead of the catalog's erased `Any Ptr` parameters.

Candidate files also declare referenced public procedures whose bodies live in
other `.bas` files when no shared `.bi` declares them. This lets the per-
procedure compiler check see the same cross-module interfaces that the full
FreeBASIC build sees. Private and `Static` procedures remain module-local, and
multiline procedure headers are left for the owning module to resolve.
FreeBASIC treats names without regard to case, while C distinguishes case.
When an included `.bi` defines a macro whose name collides with a translated C
procedure after case folding, the candidate emits `#undef` after its includes.
The C preprocessor has already expanded source uses of that macro, so the
procedure can retain its C spelling and `Alias` without colliding in BASIC.

`translate-simple-tree` applies the same filter to every engine `.c` file and
writes one candidate `.bas` file per source file. The output directory must
already exist. Test-support source files are skipped. Generated code remains a
candidate until its source context, FreeBASIC types, and external dependencies
have been reviewed. The converter does not evaluate C preprocessor branches,
and a function is skipped if any statement falls outside its supported subset.

`api-routines` and the standalone `api_routines` frontend generate SQLite's
extension API pointer table through the same adapter. The adapter reads the
preprocessed `sqlite3Apis` initializer, checks its field count against
`sqlite3_api_routines`, and uses `PORTING_FUNCTIONS.csv` to leave unavailable
functions null. It also scans public C aliases defined in the owner source
directory, so generated FreeBASIC implementations that have no C function-body
row in the ledger can still back an API slot. During that scan, the old output
table included under the stable `sqlite3_extension_api_table.bi` name is
excluded even when the generated output goes to a profile-specific build
directory. Regeneration must not treat the previous table's declarations as
external bindings and then erase the forward declarations the new table needs.
The `fb_src` bulk candidate targets regenerate this table after each clean
sweep. To regenerate it from an existing preprocessed loadext file:

```sh
fb_tools/c2fb/build/c2fb api-routines fb_src/build/candidates-loose/.c2fb_preprocessed/loadext.i \
  fb_src/PORTING_FUNCTIONS.csv fb_src/sqlite3_bulk_loadext.bas \
  fb_src/sqlite3_extension_api_table.bi

# Compatibility frontend with the same generator:
make -C fb_tools/c2fb api-routines
fb_tools/c2fb/build/api_routines fb_src/build/candidates-loose/.c2fb_preprocessed/loadext.i \
  fb_src/PORTING_FUNCTIONS.csv fb_src/sqlite3_bulk_loadext.bas \
  fb_src/sqlite3_extension_api_table.bi
```

`translate-preprocessed-tree` runs the host C preprocessor from this FreeBASIC
tool, then applies the same conservative translation to the selected SQLite
branches. It writes preprocessor headers and `.i` files under hidden
subdirectories of the output directory so the selected source can be reviewed.
The mode uses the default SQLite source feature profile and the requested
`SQLITE_THREADSAFE` value unless extra feature defines are supplied; it does
not read a configured `sqlite_cfg.h`. Generate the parser headers first with
`make -C fb_src regen-generated`:

```sh
fb_tools/c2fb/build/c2fb translate-preprocessed-tree src \
  fb_src/build/generated /tmp/sqlite_fb_candidates fb_src gcc 1
```

The preprocessor mode resolves conditionals and macros before translation, but
does not make the emitted candidates semantically complete. Review each body
and its dependencies before adding it to `fb_src/`. It uses the host ABI and
default source configuration. A preprocessing failure removes that source's
older candidate and returns a nonzero status.
Skipped body candidates include a `c2fb body diagnostic` comment with the
lowerer's diagnostic code and a bounded, single-line detail. The preceding
`c2fb skipped` comment still identifies bodies that already exist or were
filtered as duplicates.

This mode uses `-P`, which removes the source line markers that map preprocessed
text back to C files. Candidate comments and compile reports therefore retain
the original input path but omit line and column numbers; the `.i` file's
flattened offsets are not original-source coordinates.

`translate-preprocessed-files` takes the same arguments and a final
comma-separated list of engine `.c` or `.h` basenames. It applies the same host
ABI, generated headers, and feature defines while preprocessing only those
inputs. Selecting a header also scans its included inline and static function
bodies and writes a candidate file with a `_header` suffix. Headers and their
including `.c` files can expose the same inline body, so review and select only
the candidate that should own each body. The `fb_src` target exposes this mode
for quick layout-repair passes:

```sh
make -C fb_src bulk-candidate-files \
  CANDIDATE_DIR=build/candidates-vtab \
  SOURCE_FILES='carray.c,dbstat.c,vdbevtab.c' \
  FEATURE_DEFINES='SQLITE_ENABLE_CARRAY=1,SQLITE_ENABLE_DBSTAT_VTAB=1,SQLITE_ENABLE_BYTECODE_VTAB=1'
```

The file list accepts basenames only; test-support sources are rejected. The
target recreates its candidate directory and reconciles the function ledger,
but leaves extension API-table regeneration to the full-tree pass.
The bulk targets forward `BODY_OPTIONS` through the shared generic-body option
parser. This includes `--type-map`, `--typedef-hint`, `--rename-proc`,
`--rename-proc-prefix`, `--reuse-static-object`, `--replacement-file`,
`--include-existing`, `--keep-unresolved`, and additional preprocessor options.
For example, a source unit can reuse a port-owned static object and distinguish
ported procedures from the originals:

```sh
make -C fb_src bulk-candidate-files SOURCE_FILES=func.c \
  BODY_OPTIONS='--reuse-static-object=likeInfoAlt=sqlite3LikeCompareInfoAlt --rename-proc-prefix=c2fbCandidate_'
```

`BODY_TYPE_MAPS` remains available for existing make invocations that only
specify type maps. C2FB resolves mapped field access and `sizeof` through the
indexed FreeBASIC type; explicit mappings are the caller's layout assertion.

Candidate translation also indexes typed `Declare Function` and `Declare Sub`
signatures from `.bi` files and declarations in `.bas` files, including
continued signatures. It resolves a C call through a FreeBASIC `Alias` to the
declared FreeBASIC procedure and writes that declaration into the candidate
module when the translated body needs it.
When an existing FreeBASIC implementation uses a different pointer type at
its ABI boundary, C2FB casts pointer arguments to the indexed FreeBASIC
parameter type while retaining the C pointee type for expression lowering.
Candidate declaration emission reuses this body-signature catalog instead of
rescanning all `.bas` modules for each generated file. The catalog is still
built once for the selected FreeBASIC source directory. The C function and
record catalogs are rebuilt for each C source file. Calls that match a C name
through an existing FreeBASIC `Alias` use the declared FreeBASIC procedure
name, including runtime helpers such as `c2fb_crt_memset`.
When the C symbol table and project catalog both describe a used helper,
candidate emission keeps one prototype in the generated module.

The final optional argument is a comma-separated list of extra preprocessor
defines. This exposes opt-in engine and extension branches in one source-tree
batch, for example:

```sh
make -C fb_src bulk-candidates-loose \
  LOOSE_CANDIDATE_DIR=build/candidates-features \
  FEATURE_DEFINES='SQLITE_ENABLE_DBPAGE_VTAB=1,SQLITE_ENABLE_CARRAY=1,SQLITE_ENABLE_BYTECODE_VTAB=1,SQLITE_ENABLE_PREUPDATE_HOOK=1,SQLITE_ENABLE_STMT_SCANSTATUS=1,SQLITE_ENABLE_NORMALIZE=1'
```

`FEATURE_DEFINES` accepts macro names or `NAME=VALUE` pairs with a simple
identifier name and an alphanumeric or underscore value. Compile-check a
feature batch with matching `-d` options in `FBC`; otherwise the FreeBASIC
conditional layouts may not match the preprocessed C profile. Separate runs
are needed for feature combinations whose layouts or source branches conflict.

For a selected loose batch, use `bulk-candidate-files-loose` with the same
`SOURCE_FILES` and `FEATURE_DEFINES` variables. It keeps translated callers
whose local helper bodies were rejected. The matching
`check-bulk-candidate-files-loose` target compiles the staged file candidates.
`C2FB_DISABLE_ASSERTS=1` writes a candidate-only `assert.h` stub so C2FB can
translate code surrounded by `SQLITE_DEBUG` assertions. Each generated file
marks this omission; restore the required checks before integrating its bodies.
For a debug-profile conversion, `C2FB_RESTORE_ASSERTS=1` instead expands each
active `assert(expression)` into one call to `sqlite3DebugAssertCheck()` with the
condition and its source expression. The expansion uses `!!` so both scalar
and pointer conditions become the C integer truth value expected by the helper,
while evaluating the original expression once. The SQLite FreeBASIC debug
runtime logs and aborts when that condition is false. The two assertion options
cannot be used together. Both options only change C2FB preprocessing and do not
change an SQLite build.

Example for a debug TreeView batch:

```sh
make -C fb_src bulk-candidate-files-loose \
  LOOSE_CANDIDATE_DIR=build/candidates-debug-treeview \
  SOURCE_FILES='treeview.c,vdbeaux.c,wherecode.c' \
  FEATURE_DEFINES='SQLITE_DEBUG=1,SQLITE_ENABLE_TREETRACE=1,C2FB_DISABLE_ASSERTS=1'
make -C fb_src check-bulk-candidate-files-loose \
  LOOSE_CANDIDATE_DIR=build/candidates-debug-treeview \
  FBC='fbc -d SQLITE_DEBUG=1 -d SQLITE_ENABLE_TREETRACE=1'
```

To retain assertions in such a batch, use
`FEATURE_DEFINES='SQLITE_DEBUG=1,C2FB_RESTORE_ASSERTS=1'`. The candidate calls
the FreeBASIC debug assertion helper, so compile it with `SQLITE_DEBUG=1` and
the SQLite debug assertion module available.

STAT4 can be staged separately because it changes planner and index layouts:

```sh
make -C fb_src bulk-candidates-loose \
  LOOSE_CANDIDATE_DIR=build/candidates-stat4 \
  FEATURE_DEFINES='SQLITE_ENABLE_STAT4=1'
```

The optional `include-existing` argument to `translate-simple`,
`translate-simple-tree`, `translate-preprocessed-tree`, and
`translate-preprocessed-files` keeps C bodies even
when a FreeBASIC body with the same name already exists. Set
`INCLUDE_EXISTING=1` to use this mode from the `fb_src` make targets. Keep its
output in a separate candidate directory;
it is useful for comparing a fresh conversion with an existing manual port.

The optional final argument `1` keeps a translated caller even when one of its
source-local helper bodies was rejected. Use this mode to stage larger source
batches and inspect their missing helper declarations separately. The default
mode filters callers with rejected private dependencies. In `fb_src/`, run
`make check-bulk-candidates-loose` to write and compile-check the staged batch
under `build/candidates-loose/`. Both `bulk-candidates` make targets recreate
their reserved output directories before translation, so reports do not include
stale candidate files.

Candidate generation indexes existing FreeBASIC bodies, including `Private`
procedures. Existing private procedures are retained only when a newly emitted
candidate needs them as same-module helpers; that dependency is followed
transitively. This keeps repeated source sweeps focused on unported functions
without dropping helpers needed by a genuinely new body. A candidate that calls
an existing private procedure from another FreeBASIC module is skipped with a
diagnostic naming the helper, since that call cannot compile across modules.
The layout index also reads `Private Type` and `Public Type` declarations from
implementation `.bas` files. Their fields can bind C records for candidate
lowering, while private procedures remain unavailable as cross-module calls.
The layout scan does not make an implementation-private type visible to a
separate candidate module. C2FB skips a body that requires such a layout and
reports the missing FreeBASIC field rather than emitting a reference to the
private type; move reusable layouts to a `.bi` when the candidate must compile
independently.
Multi-file conversion builds the read-only FreeBASIC call-signature,
callable-symbol, field, local-declaration, and existing-body indexes once per
source directory, then reuses them for each C input file. C-side function and
record catalogs are still rebuilt for each input file. Start a new converter
process after changing the FreeBASIC source tree so the cached indexes reflect
those edits.
The extension API table header is included only when a candidate references the
`sqlite3Apis` table; its zero-argument table declarations are not used as a
replacement for typed public API declarations.

Generate and compile-check a complete batch from the port build directory:

```sh
make -C fb_src bulk-candidates
make -C fb_tools/c2fb check-candidates \
  CANDIDATE_DIR="$(pwd)/fb_src/build/candidates"
```

`make -C fb_src check-bulk-candidates` runs both steps. The checker writes
`compile-report.csv` in the candidate directory with procedure names, file
status, C source locations, and compiler diagnostics. It returns a nonzero
status if any file with a new body fails to compile. `THREADSAFE=0` selects the
single-thread profile for generation and checking. A successful compile does
not establish complete SQLite behavior, and candidates are not added to the
library automatically.

`make -C fb_tools/c2fb check-procedures CANDIDATE_DIR="$(pwd)/fb_src/build/candidates"`
checks each body with its reachable generated helpers and writes
`procedure-compile-report.csv`. It reports usable bodies even when another body
in the source module fails, records files with no new bodies, and retains failed
helper dependencies rather than checking callers against substitute
implementations. Each procedure row includes its C source path and line, with
column when available. Dependency discovery ignores procedure names inside
strings and FreeBASIC comments. If the compiler cannot be started, the report
records that as a failed compile with the launch error. File-level function
and source-location columns, plus per-procedure helper lists, are JSON values
inside the CSV so paths containing punctuation remain unambiguous. Definitions
that C2FB skips appear as `Translation skipped` rows, including their rejection
reason and any body diagnostic, and make the checker return nonzero.

Run the converter regressions with `make -C fb_tools/c2fb test`. The tests
compare generated procedures against compiled C on both the native and GCC
FreeBASIC backends. They also check unsupported-expression rejection, bounded
recursion, relative paths, shell quoting, preprocessing profiles, and stale
output removal. Python 3, a C compiler, Tcl, and FreeBASIC are required. The
boolean, division, conditional-evaluation, floating optimization, string-literal
storage, and `ZString` rules were checked against the local FreeBASIC compiler
and runtime sources. Matching C/BASIC structure fixtures also check fixed-array
members, pointer members, nested arrays, decay, and writes on both backends.
They also exercise opaque child pointers, callback fields, callback argument
and result handling, sequenced expression values, indexed updates, lazy side
effects, loop-condition updates, and individual-procedure compiler reports.
When a FreeBASIC source checkout is available, pass its `src` directory with
`--fbc-source-directory` to also translate and compile-check representative
GFXLIB, RTLIB, and SFXLIB modules. This optional probe writes all generated
bindings and objects under the test runner's temporary directory. It also
compares selected C record sizes and field offsets with FreeBASIC's compiled
layout, including the packed GFX image header. On Linux x86-64, it also
compile-checks the Unix X11 driver and its shared window manager with the
checkout's X11 bindings, and compiles the 24-procedure `gfx_blitter.c` unit
against the shared GFX context. Opaque pointer maps cover Xlib's `GC` handle and
glibc's `shmid_ds`; the driver translates 15 simple procedures with no skips.
The window manager translates 28 procedures; its thread entry and initializer
are skipped because they depend on the header-local `fb_hX11DropTick` helper.
These probes use the Linux x86-64 profile. The same check recursively translates
the shared GFXLIB2 units under `core`, `data`, `draw`, `image`, `input`,
`palette`, `pixels`, `presentation`, and `text`, excluding platform drivers.
Per-file OpenGL and inline-data header profiles are applied where needed, and
every candidate is compiled. Its default profile currently leaves two
`gfx_page.c` candidates unsupported because `FB_GL_PARAMS.mode_2d` is not in
the shared context; the dedicated OpenGL profile translates and compiles all
six page procedures. The RTLIB sweep recursively covers `str_*.c` translation units
with `__NO_CTYPE`, which keeps their ctype calls aligned with FreeBASIC's CRT
bindings instead of expanding them into glibc's private `__ctype_b_loc` table.
Every generated string candidate is compiled.

```sh
python3 fb_tools/c2fb/tests/test_c2fb.py \
  --fbc-source-directory=/path/to/fbc/src
```

The 2026-10-31 regression run passed 11,154 C/FreeBASIC behavior comparisons
on both the native and GCC backends. It accepted 166 candidates and rejected 34
unsupported functions. The suite checks generic C `va_list` declarations,
file-scope union generation, nested record layouts, array compound literals,
and the SQLite-specific `defines`, `fp-tables`, `functions`, and
`reconcile-functions` commands. The SFX source check compiles 31 FreeBASIC
modules, including 24 reviewed C2FB translations, and replaces 27 present C
peers in the Make graph. Its 67-file root C sweep
produces 456 additional candidates with zero skips and compiles every candidate
object on Linux x86-64. The C2FB candidate and integrated Basic SFX debug
helpers also match the C implementation for disabled and enabled environment
values and variadic formatting. The MIDI pause candidate and integrated Basic
module match C for stopped, active, already-paused, and reset states. The music
status candidate and integrated Basic module match C for null, stopped, active,
paused, stale-voice, and mixed-voice states. The music pause and resume
candidates and Basic modules also match C across readiness, playback-state,
voice-state, lock, and debug-message cases. The stop candidate and Basic module
match C for public and caller-locked stop paths, including stale voice pointers.
The music-play candidate and Basic module match C for readiness, asset loading,
allocation failure, loop-rate conversion, restart, and debug cases. The music
loader candidate and Basic module match C for decoder errors, invalid frame or
channel counts, mono conversion, memory-allocation failure, replacement,
unload, and debug output.
The indexed SFX loader candidate and Basic module match C for ID bounds,
decoder errors, ownership, replacement, unload, voice selection, mono
conversion, and debug output.

The buffer candidate and reviewed Basic module match C for allocation,
invalid-size handling, indexed sample bounds, frame-oriented access, clearing,
shutdown, and formatted debug output.

The envelope candidate and reviewed Basic module match C for default values,
clamping, voice assignment, attack/decay/sustain/release transitions,
zero-duration phases, invalid voice envelope IDs, and debug formatting. The C
and Basic implementations both reject an invalid envelope ID before indexing
the context table.

The instrument candidate and reviewed Basic module match C for readiness,
definition bounds and clamping, channel assignment, default and configured
wave/envelope selection, reset, and debug output.

The waveform candidate and reviewed Basic module match C for all five
waveforms, phase boundaries and wrapping, cached phase steps, white and
sample-and-hold noise, invalid inputs, and debug output. The FreeBASIC CRT
binding now exposes the target's `RAND_MAX`, which the port uses to preserve
the C random-noise range.

The voice candidate and reviewed Basic module match C for initialization,
locked and public allocation, playback setup, sample advancement, lock
boundaries, type/channel stop/pause/resume, status precedence, and pool
exhaustion. All 20 source procedures translate and compile.

The oscillator candidate and reviewed Basic module match C for phase-step
caching, reset, all waveform dispatch paths, the interpolated sine table,
wrapped and nonfinite phase inputs, white and sample-and-hold noise, and
frequency changes. All 13 source procedures translate and compile.

The mixer candidate and target-specific Basic module match C for clamp,
buffer clearing, channel settings, voice allocation, scalar mixing, and
processing with both scalar and SSE2 paths enabled. C2FB translates and
compiles all 31 mixer procedures; the FBC source
graph selects this module on Linux x86-64 and retains the C mixer on ARM and
Win32.

The GFXLIB2 image-info candidate and Linux x86-64 Basic module match C for
legacy and current image headers, invalid and null inputs, data pointers and
sizes, and the 32-bit and 64-bit wrappers. C2FB translates all three source
procedures; the source graph selects the Basic module on Linux x86-64 and keeps
the C implementation for other targets.

The current Linux x86-64 source graph provides the denominator for measuring
how much library code has moved to FreeBASIC. C2FB-derived modules replace
matching C units; other existing Basic modules are counted separately.

| Library | Selected source units | FreeBASIC units | C2FB-derived units |
| --- | ---: | ---: | ---: |
| RTLIB | 517 | 31 (6.0%) | 29 (5.6%) |
| GFXLIB2 | 82 | 12 (14.6%) | 12 (14.6%) |
| GFXLIB3 | 52 | 1 (1.9%) | 1 (1.9%) |
| SFXLIB | 77 | 38 (49.4%) | 31 (40.3%) |
| **Total** | **728** | **82 (11.3%)** | **73 (10.0%)** |

These are selected translation units in the Linux x86-64 Make graph, not a
claim that every platform's library has the same coverage. The current source-
library checks compile all 38 selected FreeBASIC SFX modules and verify their context
layout and focused runtime behavior. The music-context prefix matches x86-64
and i386 C layouts. The RTLIB check verifies
that the Make graph selects the LCASE and UCASE Basic wrappers and the
StrReverse port in place of their C peers, exercises generic, Unix, target,
and target-architecture source precedence, tests their C ABI, and translates
and compiles each original C source as a candidate with zero skips. Run these checks with the compiler
source tree and keep the converter executable outside the checkout:

The RTLIB check now includes Linux x86-64 C2FB ports for `ASC`, variadic
`CHR$`, `StrReverse`, and the `BIN$`, `HEX$`, and `OCT$` numeric formatting
families. ASC coverage includes null descriptors, invalid positions, embedded NUL bytes,
and high-bit bytes. CHR$ coverage includes empty, mixed-byte, and 32-argument
calls. The numeric-formatting check compares 31 representative calls across
the C reference, generated C2FB candidates, and integrated FreeBASIC modules,
including zero values, explicit widths, truncation, 64-bit values, and pointer
formatting. The StrReverse check covers empty strings, embedded NUL and high-bit
bytes, and temporary-string ownership. The candidate sweep processes 25 source
files, translates 48 procedures, and skips none.

The GFXLIB2 check verifies the Make graph selects `gfx_vsync.bas` in place of
its C peer and the Linux x86-64 image-info, screen-info, PNG, palette
mutation, VGA emulation, and 32-bit/64-bit palette-get, palette-get-using, and
palette-using modules in place of their C peers, while retaining the C units
on other targets. It checks the VSync context-prefix offsets and compares both VSync implementations
for absent graphics state, an absent driver
callback, and an active callback. The image-info comparison covers legacy and
current headers, invalid and null inputs, data pointers and sizes, and the
32-bit and 64-bit entry points. The screen-info comparison covers active and
absent graphics state, driver strings, and all three result-width ABIs. The
PNG comparison covers RGBA, RGB565, indexed output, indexed-to-RGB loading,
byte-identical saves, decoded pixels and palettes, and corrupt image data.
The palette lookup comparisons cover
null graphics state, index wrapping, full RGB output, the compatibility
grayscale path, and whole-palette bounds for both 32-bit and 64-bit APIs. The
palette mutation comparison covers RGB and legacy color-index updates, mode
restores, callbacks, dirty lines, and 32-bit/64-bit whole-palette writes. C2FB
translates and compiles all 61 PNG procedures, all three screen-info
procedures, all six scalar palette mutation procedures, both whole-palette
write procedures, both VGA port procedures, and all four palette lookup
procedures. The VGA comparison checks persistent register sequences and
palette reads and writes through the Basic palette mutation module.
The GFXLIB3 check verifies the generic logger's Basic replacement, translates
and compiles its C2FB candidate, and compares both implementations' stderr
output with the C source.

```sh
make -C fb_tools/c2fb check-freebasic-sfx \
  FBC_SOURCE_DIR=/path/to/fbc/src \
  FBC=/path/to/fbc/bin/fbc \
  TARGET=/tmp/c2fb-fbc-check/c2fb

make -C fb_tools/c2fb check-freebasic-rtlib \
  FBC_SOURCE_DIR=/path/to/fbc/src \
  FBC=/path/to/fbc/bin/fbc \
  TARGET=/tmp/c2fb-fbc-check/c2fb

make -C fb_tools/c2fb check-freebasic-gfx \
  FBC_SOURCE_DIR=/path/to/fbc/src \
  FBC=/path/to/fbc/bin/fbc \
  TARGET=/tmp/c2fb-fbc-check/c2fb

make -C fb_tools/c2fb check-freebasic-gfx3 \
  FBC_SOURCE_DIR=/path/to/fbc/src \
  FBC=/path/to/fbc/bin/fbc \
  TARGET=/tmp/c2fb-fbc-check/c2fb

rm -rf /tmp/c2fb-fbc-check
```

For a read-only comparison against an existing fbfrog test tree, run
`audit_fbfrog.py` with its `tests` directory. C++ fixture paths, C++ header
suffixes, and visible C++ default arguments select C++ preprocessing. Headers
with recognized platform conditions are audited across representative target
profiles. C++ fixture runs enable the traditional-preprocessor fallback, and the
auditor retries a failed C++ fixture with `clang++` when it is available. The
declarations scope does not attempt to translate C++ function bodies. Simple
`-declareversions` /
`-selectversion` scripts are audited through the C2FB target matrix; unsupported
fbfrog script options are counted as skipped. The default `macros` scope
compares emitted macro names. The `declarations` scope also compares top-level
binding names from generated headers and translated C body candidates, counting
source identifiers and explicit renames while ignoring fbfrog-only helper
names, comments, or record members. The auditor writes outputs to a temporary directory and does not copy or
modify fbfrog sources or fixtures. Generic-header audit runs include static
objects as private module storage to match fbfrog's file-scope bindings. Both
scopes measure name coverage only by default; they do not establish semantic
or ABI equivalence. In the `macros` scope, `--compare-macro-values`
also compiles and runs paired probes from the matching constant and macro
definitions, so unrelated declarations do not block a value check. The C oracle
first includes the original header in its probe, preserving `_Pragma` state
changes; if unrelated declarations prevent that compile, it falls back to the
isolated active-macro subset. Stateful push/pop cases are skipped when the
source-context probe fails instead of treating a `-dM` snapshot as final C
semantics. When FBFrog and C2FB disagree, the C oracle identifies which output
matches C; `--strict` does not count an FBFrog-only divergence as a C2FB value
failure. The audit still reports that divergence. It covers
unique, unconditional object-like integer macros, direct decimal floating
literals, narrow and wide string literals including embedded NUL bytes, and
simple function-like integer expressions with up to four parameters, testing
each parameter with values from 1 through 3. Floating values are compared by
their `Single` or `Double` bit patterns. Strings are compared by complete byte
or code-unit sequences; `sizeof` on the C literal supplies the length so bytes
after an embedded NUL are checked too. Wide-string probes run only when C and
FreeBASIC use the same `wchar_t` width. The audit follows explicit identifier
renames and `-clong32`, and checks target-filter
profiles with matching FreeBASIC conditional defines. Version-selector
matrices supported by the simple `-declareversions` / `-selectversion` parser
also compare per-version integer values and empty-macro presence. More complex
script matrices and options that replace or remove macro bodies remain outside
this check, as do other function-like expressions and hexadecimal floating
literals.
The local FBFrog `lex` fixture marks direct hexadecimal-float macros as TODO;
C2FB's own `generic-header` regression still compares direct hexadecimal
single and double literals against C.
In the `declarations` scope, `--compare-record-layouts` also compares named
record and typedef sizes plus addressable field offsets against the C compiler
for direct and profile-generated bindings. It reports FBFrog-versus-C and
C2FB-versus-C differences separately, so a broken baseline does not make a
correct C2FB layout look wrong. Types or offsets that cannot be probed are
listed as skipped; skip counts are grouped by probe stage and C2FB examples
are shown separately. C2FB layout skips are also split by whether the paired
FBFrog baseline compiles and whether its target-profile layout probe succeeds.
`--strict` treats those skips as incomplete evidence.
Use `--fail-on-c2fb-layout-mismatch` to fail only when a measured C2FB record
layout differs from C; unavailable probes remain reported skips.
The measurements use the supplied compiler targets; simulated OS defines on a
host compiler do not establish a foreign ABI.
If a C wrapper fails because of unrelated declarations in the header, the audit
uses Clang's record-layout dump when its target matches the selected C compiler.
For integer macro values, a failed C probe is split into bounded smaller batches
so one invalid FBFrog-only expression does not hide values from neighboring
macros. Stateful `push_macro`/`pop_macro` fixtures remain unsplit because their
source context determines the active definition.
Explicit `--array-size` overrides intentionally change flexible-array storage,
so the audit still checks their member offsets but excludes the affected
record's `SizeOf` value from C ABI comparison.
Add `--compile-bindings --fbc fbc` to compile each paired fbfrog baseline and
each direct or per-profile C2FB header with the FreeBASIC compiler. Conditional
selectors are not compiled because they intentionally reject configurations
that match no profile. The audit reports baseline failures separately and calls
out C2FB header failures when the corresponding fbfrog baseline compiles; all
wrappers and objects remain inside the audit's temporary directory. It also
separates missing names from FBC-compilable baselines and from baselines that
FBC rejects, so invalid fbfrog output is not mistaken for a usable parity gap.
With `--compile-bindings`, `--strict` treats missing names on a non-compiling
FBFrog baseline as unverified; gaps against compiling baselines remain failures.
When `--fbc` points to a compiler inside an FBC source checkout, the audit finds
that checkout's `inc` directory automatically. Use repeatable
`--fbc-include-directory DIR` options when the compiler's headers live elsewhere.
In the `declarations` scope, add `--compile-body-candidates` to compile each
generated C2FB body candidate together with its binding. This checks that the
header and body outputs compose; C++ bodies remain outside this check.
Pass `--report-all-compile-failures` to list failed FBFrog baselines as well as
every failed C2FB output. This makes it possible to separate converter
regressions on compilable baselines from syntax or language gaps already
present in the FBFrog fixture output.

Run `make check-fbfrog-parity` for strict declaration/body and macro/value
checks, plus a record-layout pass that fails on measured C2FB-versus-C
mismatches. Unavailable layout probes remain reported as skips, since those
often correspond to fixtures that FBC cannot compile. The target requires an
external FBFrog test directory and keeps generated bindings and probes in
temporary directories:

```sh
make -C fb_tools/c2fb check-fbfrog-parity \
  FBFROG_TESTS=/path/to/fbfrog/tests \
  FBC=/path/to/fbc/bin/fbc \
  TARGET=/tmp/c2fb-parity/c2fb
```

```sh
python3 fb_tools/c2fb/audit_fbfrog.py \
  --converter fb_tools/c2fb/build/c2fb \
  --fbfrog-tests /path/to/fbfrog/tests \
  --scope declarations \
  --compile-bindings \
  --compile-body-candidates \
  --report-all-compile-failures

python3 fb_tools/c2fb/audit_fbfrog.py \
  --converter fb_tools/c2fb/build/c2fb \
  --fbfrog-tests /path/to/fbfrog/tests \
  --scope macros \
  --compile-bindings \
  --compare-macro-values \
  --report-all-compile-failures

python3 fb_tools/c2fb/audit_fbfrog.py \
  --converter fb_tools/c2fb/build/c2fb \
  --fbfrog-tests /path/to/fbfrog/tests \
  --scope declarations \
  --compile-bindings \
  --compare-record-layouts
```

On 2026-10-20, the local FBFrog test tree had 438 paired fixtures. The macro
audit emitted all 774 expected names. Its five integer-value differences were
all confirmed by the C oracle as FBFrog divergences; C2FB had no value mismatch
against C. The declaration audit matched 2,018 of 2,029 names. After adding
incomplete external object support, a compile-only refresh found that 298/438
FBFrog baselines and 1,663/1,682 C2FB headers compiled, with no C2FB compile
failures against FBC-compilable baselines. The 11 missing names remained only
among non-compiling baselines. A fresh strict declaration audit with body
candidate compilation found no missing names or body compile failures against
FBC-compilable baselines; it compiled 15/17 binding-plus-body outputs. The
earlier full body/layout sweep checked 1,386 layout values across 570 probes
with no C2FB/C mismatches; its single FBFrog/C layout difference was reported
separately. These counts are evidence for that fixture tree and compiler
profile, not a claim that every C declaration or ABI is supported.

A fresh strict audit on 2026-10-30 against the same 438-fixture tree matched all
774 macro names. It evaluated 437 integer macro values and checked 393 values
against C across 90 fixture/profile probes; C2FB had no C-oracle mismatch. Five
FBFrog/C2FB differences were confirmed by C as FBFrog divergences. The
declaration audit again matched 2,018/2,029 names, compiled 1,659/1,682 C2FB
headers and 15/17 binding-plus-body candidates, and found zero missing names or
compile failures against FBC-compilable FBFrog baselines. The 11 remaining
unmatched names are in baselines FBC rejects.

A full declaration/body/layout rerun on 2026-10-31 used a compiler rebuilt from
the current FBC source tree. It compiled 1,659/1,682 C2FB headers and 15/17
binding-plus-body candidates, with zero C2FB compile failures on compilable
FBFrog baselines. It compared 1,380 record-layout values across 568 probes and
found no C2FB/C mismatch; the single FBFrog/C divergence remains reported
separately. The declaration count stayed at 2,018/2,029, with all 11 absent
names belonging to FBC-rejected FBFrog baselines. `--report-all-compile-failures`
now lists those baseline failures as well as C2FB failures for easier triage.

A focused `lex/lex.h` value audit compared 57 floating, narrow-string, and
wide-string macro values against both FBFrog and C, including embedded-NUL
strings such as `D1`, `D4`, and `H7`, plus the wide literal `B2`. It found no
FBFrog/C2FB or C2FB/C differences. The separate integer-value probe for that
fixture remains unavailable because GCC rejects FBFrog's FreeBASIC-specific
`i8` literal suffixes.

The full strict macro audit with those checks enabled again matched all 774
macro names and evaluated 461 integer values. It checked 443 integer values
against C across 95 fixture/profile probes, plus 71 floating and string values
across 6 probes, with no C2FB/C mismatch. The five remaining FBFrog/C2FB value
differences were confirmed as FBFrog divergences by C; 18 individual C integer
expressions remain unprobeable, including FreeBASIC-only literal suffixes and
brace initializers.

FBC now accepts the isolated `extern struct T1 x1` case produced by
`-addforwarddecl T1`; the full local FBFrog fixture still fails on its separate
`extern struct T2 x2` declaration. A focused paired audit of the isolated T1
declaration compiled both FBFrog and C2FB outputs and matched both emitted
names. In the focused `rename/typedef.h` audit, C2FB compiled its output while
FBFrog's `byte` typedef rename was rejected as a keyword; C2FB's `byte_`
binding is the one intentionally unmatched name.

Build and run it with:

```sh
make -C fb_tools/c2fb
fb_tools/c2fb/build/c2fb src/sqlite.h.in /tmp/sqlite3_api_declarations.bi
fb_tools/c2fb/build/c2fb src/sqliteInt.h /tmp/sqlite3_internal_api_declarations.bi
fb_tools/c2fb/build/c2fb defines src/sqlite.h.in /tmp/sqlite3_api_constants.bi
fb_tools/c2fb/build/c2fb fp-tables src/util.c /tmp/sqlite3_fp10_tables.bi
fb_tools/c2fb/build/c2fb functions src fb_src/PORTING_FUNCTIONS.csv
fb_tools/c2fb/build/c2fb reconcile-functions fb_src/PORTING_FUNCTIONS.csv fb_src
```

Generated SQLite and generic ABI headers define the guarded `c2fb_c_*`,
`c2fb_int64`, `c2fb_uint64`, and `c2fb_size_t` aliases used by their
declarations. Body candidates share those guards, so the same alias definitions
work when headers and candidate modules are included in either order.

The tool itself is written in FreeBASIC. Declaration mode expects one C
declaration per semicolon and skips preprocessor branches rather than evaluating
them. Duplicate function names are emitted only once. C ellipsis parameters
are preserved as FreeBASIC variadic procedure declarations, and variadic
functions use CDecl even if a source attribute requests StdCall. Function-pointer
parameters and engine object pointers are represented as opaque `Any Ptr`
values so ABI headers can compile without engine structure definitions. Body
conversion uses typed object pointers separately. Scalar `i8` values retain
their signed byte width. Conditional branches are not evaluated and require
source-level review.

`defines` mode accepts integer literals, `SQLITE_*` references, parentheses,
and the bitwise operators `|`, `&`, `^`, `~`, `<<`, and `>>`. It omits build
configuration macros and expressions with unsupported tokens or unresolved
references. Review generated output before using it as an ABI or behavior
contract; the converter does not evaluate C preprocessor conditionals.
`fp-tables` recognizes `aBase`, `aScale`, and `aScaleLo` and validates their
expected element counts before writing split 32-bit words for FreeBASIC.

## Explicitly mapped record sizes (2026-10-19)

Generic body conversion now resolves `sizeof(T)` and `sizeof(*p)` through an
explicit `--type-map=T=FreeBASICType` when the mapped FreeBASIC type has an
indexed record layout. This also lets surrounding arithmetic and `memset()`
use the mapped size. The new regression compares a pair of mapped records,
the explicit type form, and a zeroed mapped record with C on native and GCC
FreeBASIC backends. Mapping `Fts3SegFilter` to `SqliteFts3SegFilter` now lets
C2FB emit all 104 write-unit bodies from `ext/fts3/fts3_write.c`; 13 bodies
already implemented in the port are omitted and the pass reports no
unsupported routines.

The full regression suite after this change passed all 11,154 C/FreeBASIC
behavior comparisons on native and GCC backends. It accepted 166 candidates
and rejected 36 intentionally unsupported functions; the mapped-record size
regression above runs in both backends as part of this suite.

## Automatic multidimensional array initializers (2026-10-31)

Automatic fixed-bound `const` multidimensional arrays can now be initialized
and read in translated bodies. Initializer flattening now tracks the C cursor
through nested arrays, so scalar prefixes, braces around scalar leaves, and
later braced subarrays select the same elements as C. Record-array element
groups remain intact for field initialization. The core regression suite
passed all 11,154 native and GCC behavior comparisons; the rejection fixture
lists 34 unsupported functions instead of 36.

## Const-qualified automatic VLAs (2026-11-01)

C permits uninitialized automatic `const` arrays with fixed or runtime bounds.
C2FB now lowers these arrays while carrying their read-only property through
the body expression model; generated FreeBASIC backing storage stays mutable
so runtime bounds can use `ReDim`. Regressions compare C and FreeBASIC for
fixed matrices and one- and two-dimensional runtime extents, and confirm that
a write through a const VLA still rejects the whole function. The full C2FB
suite passed 11,163 C/FreeBASIC behavior comparisons on both native and GCC
backends, accepted 167 candidates, and rejected 32 unsupported functions.

## Side-effecting multidimensional VLA bounds (2026-11-01)

Multidimensional VLA bounds now use the sequenced-expression path at the
declaration site, so supported updates are evaluated once and their captured
values determine the complete array extent. Regressions cover a postfix update
in one dimension and independent updates in two dimensions; 50 inputs for each
case matched C on both FreeBASIC backends. The full C2FB suite then passed
11,213 behavior comparisons per backend, accepted 169 candidates, and rejected
31 unsupported functions.

## Large automatic array initializers (2026-11-01)

Fixed-bound non-const automatic scalar and pointer arrays above the inline
storage limit now use managed arrays when their positional initializer has at
most 262,144 elements. `ReDim` zero-fills omitted elements, and C2FB emits only
the explicit initializer assignments at the C declaration site. Regressions
compare sparse 65,536-element vectors and matrices against C on native and GCC
backends. The complete C2FB suite passed 11,215 behavior comparisons per
backend, accepted 171 candidates, and reported 30 unsupported functions.

## SQLite B-tree record sizes (2026-10-21)

SQLite body lowering treats `BtCursor` and `BtLock` sizes as known because the
FreeBASIC records match their C layouts. A regression compares their sizes and
selected offsets with C, then checks `memset(cursor, 0, sizeof(*cursor))` on
both FreeBASIC backends. `Btree` is accepted only when the active C field list
matches the mapped FreeBASIC record; the regression checks its size and offsets
and confirms that `SQLITE_OMIT_SHARED_CACHE` disables the mapping. This enables
`sqlite3BtreeOpen`, which allocates the record with `sizeof(Btree)`. `MemPage`
uses the FreeBASIC record's size even though it differs from C by eight bytes:
the port appends `aiOvflSize` scratch storage, and pager allocations must
reserve that storage for FreeBASIC page operations. The regression checks that
the translated size equals `SizeOf(MemPage)` and stays eight bytes larger than
C `sizeof(MemPage)`. With these verified layouts, the current `btree.c`
candidate pass also translates `allocateTempSpace`, `setSharedCacheTableLock`,
`btreeCursor`, and `btreeCursorWithLock`.

## 128-bit integer declarations (2026-10-20)

FBC accepts `Integer<128>` and `UInteger<128>` as 16-byte scalar types. C2FB
maps GNU `__int128`, `unsigned __int128`, and their common typedef spellings to
those types, so Linux `__u128` typedefs with `aligned(16)` retain the field
offsets expected by C. GCC and LLVM use their native 128-bit integer type when
the target supports it. On 32-bit x86, GCC and Clang emit a 16-byte aligned
two-word type and lower arithmetic through the FreeBASIC runtime; generated
procedures can pass and return that type by value. C functions using the same
aligned pair structure have a tested i386 ABI match. The execution tests cover
GAS32 and GCC i386 calls in both directions with C. A C source declaration
using native `__int128` still requires a compiler that supports that type.
Native GAS and GAS64 lower arithmetic through the same runtime. GAS32 passes
128-bit arguments as 16-byte stack copies and returns values through a hidden
result pointer. GAS64 SysV uses its two-register ABI where available and stack
arguments when those registers are exhausted. The GAS64 non-SysV path passes
the 16-byte value through a caller-owned copy and returns through a hidden
result pointer; the Windows x64 backend has an assembly test for register
slots, stack slots, and nested calls.
Generic-body tests run translated 128-bit addition and increment against C on
the native and GCC backends. With `--fbc-source-directory` on Linux x86-64,
they also call those translated bodies from C through the aligned i386 pair ABI.

## Indexed body record fields (2026-10-20)

Generic body conversion indexes C record members by exact source owner and
field name. FreeBASIC collision checks use the exact owner and
case-insensitive field name, matching FreeBASIC's member lookup. The project
layout catalog also indexes public FreeBASIC fields by owner and member, so
member resolution does not scan the complete accumulated catalog for each C
field access. The maps preserve first-match behavior and rebuild after a
generated record is rolled back. Their capacity remains bounded by the body
record-field limit.

The existing five-unit catalog-growth regression passes with 6,600 fields per
unit. Targeted C/FreeBASIC checks also pass for typedef-backed nested fields and
keyword-field collisions. The catalog-growth run took 6:01 on a host with a
load average near 150, so this run does not establish a comparative speedup.

## Large C enum indexing (2026-10-30)

Generic enum members use an exact-name index, and body reindexing retries only
values that may become resolvable after typedef or object-extent indexing. A
single enum list can contain up to the generic header output-name limit; the
regression generates, compiles, and runs a 2,048-member enum.

On the local Linux x86-64 FBC GFX3/Vulkan source, the type-only header pass fell
from 287.7 to 225.8 seconds, and the body pass fell from 455.5 to 322.8 seconds.
The complete source-unit pass fell from 743.2 to 548.6 seconds. The type context
was byte-identical; body output folded known enum-dependent array sizes to
numeric constants and compiled with FBC. These timings are a local benchmark,
not a performance guarantee for other targets or headers.

## FBC library integration coverage

Generated candidates are not counted as converted library code. To measure the
active FBC Make source graph, including only Basic modules selected in place of
their C peers, run:

```sh
make -C fb_tools/c2fb report-library-coverage \
  FBC_SOURCE_DIR=/path/to/fbc/src
```

The report separates C2FB-marked Basic modules from other Basic modules and
remaining C units for RTLIB, GFXLIB2, GFXLIB3, and SFXLIB. Pass
`--format=json` to `report_fbc_library_coverage.py` for machine-readable counts,
or add `--make-arg NAME=VALUE` when measuring another Make-selected target.

<!-- end of README.md -->
