# C2FB architecture

C2FB has grown from a SQLite header helper into several related translators.
The goal of this migration is to give those paths one front-end model and one
target context, while retaining the current command modes and their behavior.

## Translation pipeline

Each command should act as an input or output adapter around the same pipeline:

1. An input adapter selects a file, compiler configuration, and translation
   task. Preprocessing remains an adapter because the C compiler selects
   target-dependent declarations and macros.
2. The front-end tokenizes C and builds declaration, type, expression, and
   function-body models. It records source spans so diagnostics can point back
   to the original input.
3. A translation-unit context owns the target ABI profile, type and symbol
   catalogs, caller overrides, and diagnostics for that input. SQLite-specific
   type names belong in the SQLite profile; generic C mappings belong in the
   generic profile.
4. Lowering passes consume those models to handle declarations, records,
   macros, constants, tables, and supported function bodies. A pass should not
   re-parse source text already represented by the front-end.
5. Output backends format FreeBASIC bindings, body candidates, audit reports,
   and function indexes. Lowering should not write directly to an output file.

Every supported command now enters through a typed request and one dispatcher.
The translation passes share declaration, type, symbol, diagnostic, and output
models, while adapters retain mode-specific option semantics, source-span
accounting, and include order.

## Command adapter map

| Command family | Request | Shared path and owning adapter |
|---|---|---|
| `defines` | `C2fbFileConversionRequestModel` | Shared directive and integer-expression parsing; SQLite define policy and generated-file output. |
| `translate-simple*` | `C2fbBodyTranslationRequestModel` | Shared per-file body pipeline, declaration scanner, symbol/type context, and candidate-file output. |
| `translate-simple-generic-c*` | `C2fbGenericBodyInputModel` with a shared body request | Generic preprocessing and options adapter, then the same body pipeline and generic policy. |
| `translate-preprocessed-*` | `C2fbPreprocessedBodyRequestModel` | Typed tree versus file-list selection, SQLite compiler configuration, then the same body pipeline. |
| `fp-tables` | `C2fbFileConversionRequestModel` | SQLite table validation through the shared physical C-source reader, integer-array binding, and generated-file output. |
| `api-routines` | `C2fbApiRoutinesRequestModel` | `c2fb_api_routines_adapter.bi` delegates extension API generation to the shared CSV and generated-file backends. |
| `functions` | `C2fbFunctionIndexRequestModel` | Inventory profile of the shared declaration scanner over source-unit state, with a typed C-only or C-and-header scope and CSV output. |
| `reconcile-functions` | `C2fbFunctionReconcileRequestModel` | Shared text input for FreeBASIC procedure indexing and CSV rows, then the common CSV writer. |
| `generic-header` | `C2fbGenericHeaderInputModel` with the shared file request | Generic preprocessing and policy adapter, shared declaration collection, then generic lowering passes. |
| default SQLite header mode | `C2fbFileConversionRequestModel` | Shared declaration collection and prototype lowering under the SQLite ABI profile. |

The dispatcher initializes translation-session state only for commands that
use target mapping or lowering. Function inventory uses `C2fbSourceUnitStateModel`
per C file and leaves target mapping and lowerer state unconfigured;
reconciliation only reads FreeBASIC and CSV inputs. The table and define
utilities keep their SQLite-specific parsing rules while using the common
output and request models where those boundaries apply. The standalone
`api_routines` executable is now a compatibility frontend to the same generator
core and summary formatter used by `c2fb api-routines`; command error reporting
stays in the command adapter.
The `fb_src` bulk and loose-candidate targets invoke the dispatcher command, so
the project workflow uses the common adapter instead of the standalone binary.

`c2fb_compile_commands.py` is the project-batch input adapter. It normalizes
compiler database entries into `CompileCommandModel`, prepares a distinct
output signature in `PreparedCompileCommandModel`, and invokes
`translate-simple-generic-c`. Compiler flag filtering and staged publication
stay in the batch adapter; C parsing and FreeBASIC lowering stay in C2FB.
`c2fb_target_matrix.py` runs the generic-header pipeline once per C compiler
profile. It can also write a FreeBASIC target selector that includes exactly
one profile binding, keeping different ABI record layouts in separate files
while giving consumers one stable include path.

## Shared model in use

`c2fb_model.bi` defines the shared front-end records and the backend-neutral
diagnostic, record-binding, procedure-binding, and body-candidate models. The
output backend consumes these models rather than defining types that leak back
into translation state. It also owns `C2fbConversionSummaryModel`, which
accumulates pass totals without making the output formatter their owner. Common
converted and skipped totals sit at the root; SQLite-define ambiguity and
generic-header object/layout/macro totals live in their owning submodels.
`C2fbDiagnosticStateModel` groups the active source cursor with accumulated
diagnostics, which use a typed severity category. A declarator model retains
its name, token span, function parameter positions, and ordered pointer, array,
and function operators as typed declarator kinds. A function declaration model
also records the specifier range.
`C2fbSourceUnitStateModel` owns declarations, source locations, diagnostics, and
raw library pragma facts without requiring a target profile. The function
inventory uses that source-only state; header and body conversion add target,
symbol-table, and mode-specific lowering state through `C2fbTranslationContext`.
The scanner records library pragma values in source-unit state, and the generic
header pipeline applies them to generic policy after collection.
`c2fb_declarations.bi` builds these models, and generic typedefs, record fields,
external objects, function prototypes, body symbol indexing, and body
candidates now consume the shared declarator model. The older primitive-output
parser adapters have been removed.
Declaration and record categories use typed enums so scanner and lowering
passes share the same plain/record/function and struct/union/enum identities.

`c2fb_limits.bi` owns the shared bounds for tokens, declarations, symbols,
body-local storage, generated arrays, and command input expansion. Command and
symbol kinds are named enums beside their request and symbol models in
`c2fb_model.bi`; the CLI driver no longer owns shared policy constants or
integer discriminants.
The declaration table has its own 32,768-entry bound for platform SDK headers;
function and candidate workspaces remain capped at 8,192 entries to keep their
fixed-size storage bounded. Generic-header symbol and emitted-name indexes use
a separate 40,960-entry bound so declarations and macro names do not consume
the smaller function workspace.
`C2fbBodyTranslationRequestModel` owns the source/output selection, file or
tree shape, and translation options shared by direct and generic body commands.
Generic preprocessor arguments stay in `C2fbGenericBodyInputModel`, and the
SQLite project-wide preprocessing request retains its own source selection.
Generic-header input carries the same `C2fbFileConversionRequestModel` used by
SQLite header, define, and floating-point table commands, alongside its
generic-only argument list.
Every selected or preprocessed C file becomes a
`C2fbBodyFileTranslationRequestModel` before entering `c2fb_body_pipeline.bi`.
The command dispatcher hands body requests to their adapters; each adapter
selects file or tree behavior and submits concrete files through that same
typed pipeline contract.
`c2fb_contracts.bi` collects the internal service declarations needed to keep
FreeBASIC's textual include order explicit without turning the command driver
into a second interface file.
`c2fb.bas` includes generic policy, header state, C type parsing, SQLite type
policy, and type resolution explicitly after replacement helpers, rather than
relying on nested includes in those modules.
`c2fb_context.bi` validates and installs the active target and source-map mode
as one `C2fbTranslationTargetStateModel`; adapters pass typed selections and
lowerers read the resulting context. A fresh context starts with
`C2FB_TARGET_INVALID`, and type mapping rejects it until an adapter selects
SQLite or generic behavior.

`c2fb_lexer.bi` owns token-array growth and the bounded C declaration
tokenizer. Generic-header collection requests replacement tokens from the
shared macro parser, and declaration scanning uses the same tokenizer; numeric
define conversion keeps raw replacement text and avoids tokenizing unused data.
`c2fb_macro_syntax.bi` parses `#define` and `#undef` syntax into the shared
macro model; SQLite define policy and generic-header expansion stay with their
own consumers. `c2fb_inputs.bi` now only normalizes command arguments into typed
requests, while `c2fb_arguments.bi` owns response-file expansion and shell
quoting.
`c2fb_generic_macro_collection.bi` owns preprocessed macro-table collection,
undefinition tracking, and source-origin matching. `c2fb_generic_pragmas.bi`
recognizes the supported `#pragma comment(lib, ...)` form consumed by the
function scanner. `c2fb_generic_enums.bi` lowers supported enum values through
the common integer-expression translator and emits them as shared constant
bindings. It retains known numeric values so anonymous enum constants can size
fixed arrays in typedefs, record fields, and external objects.
`c2fb_generic_macro_lowering.bi` translates supported macro expressions and
aliases, including one supported call inside braced and `do/while(0)` statement
wrappers. The generic-header macro emitters call those lowering functions and
write through the common output helpers. Those emitters now live
in `c2fb_generic_macro_output.bi`, separate from macro collection and record
binding orchestration. The output pass handles direct decimal floating macro
literals as typed constants while leaving unparsed floating arithmetic for
manual review. `c2fb_generic_macro_expansion.bi` optionally asks the
configured C preprocessor to expand selected definitions, then applies only
those overrides while preserving the original source text and locations.
`c2fb_generic_forward_declarations.bi` maps requested incomplete struct and
union tags to FreeBASIC forward references, while complete record aliases keep
their normal ABI-backed type definitions.
`c2fb_generic_include_preservation.bi` reads active include directives retained
with `-dI`, matches caller C-to-FreeBASIC include mappings, and suppresses the
mapped header's flattened declarations and nested C include subtree. Source
marker include-depth flags delimit that subtree while all of its types remain
indexed for resolution.
`c2fb_generic_ordering.bi` applies caller moves to source declarations within
the generic header's existing ABI emission phases, and hoists safe scalar
externals, built-in prototypes, and requested forward-tag pointers before
simple typedefs when requested. It reports unused or type-dependent
cross-phase requests. Comma-separated
declaration items use the same move policy before individual bindings are
emitted. Declaration guard patterns
travel with each lowered output item so `#undef` and `#ifndef` handling stays
in the shared output backend rather than changing C declaration parsing.
`c2fb_generic_declarations.bi` lowers plain external declarations and
callbacks into shared bindings. `c2fb_generic_records.bi` owns record layout
preparation and emission. Supported alternating anonymous struct/union members
lower into a linear field/block item stream, which the output backend formats
as nested anonymous FreeBASIC `Type`/`Union` blocks. Named inline aggregates
use synthetic helper record layouts so their C member names remain accessible.
Trailing zero-length and flexible byte arrays have no storage item and receive
a generated tail pointer macro based on the preceding field's end address.
Scalar bitfields are emitted only when the target C and FreeBASIC storage
extents can be represented by the same bitfield container; otherwise the
containing record is skipped rather than shifting later fields.
`c2fb_generic_header_pipeline.bi` owns the generic
header's output lifecycle and pass ordering across typedefs, declarations,
enums, records, and macros. Its typedef-index, typedef-emission, and binding
passes use a named pass kind rather than combinations of integer flags.
Ordinary generic external-object lowering receives the shared declaration
model. When scanner tokens and source-text parts agree, multi-declarator lists
use `SplitC2fbTokenList` and `BuildC2fbDeclaratorPartTokens`; prototype and
object lowering consume those token parts without tokenizing them again. The
shared part builder also serves generic typedefs and body and header record
fields, keeping common specifier restoration in one place. The text path
remains as a compatibility fallback when token ranges are incomplete or do not
match the source split.
Generic-header source filters use preprocessor source paths for declarations,
records, enums, macros, and inline functions while retaining every source file
in the type index. Object-like macros from omitted paths can still resolve as
private dependencies. This supports separate bindings for headers in one
include tree; omitted types can be supplied by another generated binding.
Library pragmas retain their source locations and follow the same filter.
`c2fb_c_syntax.bi` owns C comment stripping, attribute recognition, shared
whitespace, identifier, qualifier, and digit predicates, balanced-group
scanning, bounded integer array-bound parsing, and comma-list splitting.
Generic declarations, records, symbols, expression parsing, directives, and
body lowering use those shared helpers.
`c2fb_file_input.bi` owns shared text and binary input lifecycles, including
physical line counting, raw line reads, whole-file reads, and file-size checks.
`c2fb_source_lines.bi` adds C source locations and block-comment state for
scanners, while `c2fb_directives.bi` layers logical continuation joining over
raw lines before stripping comments. Generic macro origin collection, final
macro-table collection, and SQLite numeric defines use that logical reader.
Continued numeric definitions retain their first source line while
generic-header lowering keeps its explicit continuation policy.
Response files, replacement rules, FreeBASIC project indexes, candidate-header
inspection, and SQLite preprocessor-header copying use the same text-input
lifecycle while retaining their own line interpretation. Temporary-path
checks and the standalone API-table binary inputs use the same binary-input
backend.
`c2fb_integer_expr.bi` owns the supported C integer-expression normalization
used by both SQLite numeric defines and generic-header macros. The callers
select a typed identifier policy while sharing literal validation and operator
lowering. `c2fb_sqlite_defines.bi` owns SQLite's define selection, build-input
exceptions, conditional-conflict checks, and constant output. Its
`C2fbSqliteDefineModel` keeps normalized integer expressions and conflicts
separate from generic macro expansion state.

Body candidate construction also uses `ParseCFunctionDeclarationModel` to
find the function parameter group and result declarator. It no longer scans
for the first parenthesis independently, so body lowering and header emission
share the same function binding interpretation.
`c2fb_body_declarations.bi` owns local declaration, array, string, and record
initializer lowering. Comma-separated locals share the same token-range and
common-specifier restoration helper as generic objects and record fields.
`c2fb_body_statements.bi` owns statement and control-flow parsing, and consumes
those local bindings. `c2fb_body_lowering.bi` assembles procedure signatures
and combines the lowered body with the shared binding model. The switch state
machine lives in `c2fb_body_switch.bi`; it calls the same recursive statement
parser for each case body.
`c2fb_body_pipeline.bi` owns per-file declaration indexing, function streaming,
candidate filtering, and shared body output orchestration. Simple, generic, and
SQLite-preprocessed adapters all submit their selected or preprocessed C file
to this pipeline, so target selection changes policy without forking lowering.
Source-mapped conversions lower static header helpers provisionally, then retain
only helpers reachable from selected root bodies. Rejection diagnostics from
discarded helpers are deferred with those candidates; required unsupported
helpers keep their diagnostics, while unused helpers do not pollute the output.
`c2fb_function_scanner.bi` streams top-level declarations, records, prototypes,
and definitions into the common `C2fbDeclarationModel` table. It owns comment,
quote, brace, C-linkage-block, conditional, and packing state.
Tagged record definitions nested in a record body are hoisted into that table,
including when they occur inside anonymous inline aggregates. They precede the
enclosing record so later field and prototype lowering can resolve the tag.
`c2fb_declaration_helpers.bi` removes compiler-specific attribute groups and
preserves calling-convention tokens before the shared declarator and prototype
passes inspect declarations. The declarator parser records every function
suffix position so callback result layers can retain their own call convention.
`c2fb_source_map.bi` parses GCC and Clang line markers into
`C2fbSourceLocationModel` and compares normalized source paths. Generic-header
macro-origin matching and function scanning use the same marker parser; the
scanner applies marker results to declaration locations and root-source
selection. The model also retains the system-header marker flag. Generic macro
collection uses it to keep compiler-injected `stdc-predef.h` values private
without suppressing API macros from ordinary system headers. Function
definitions retain marker-derived source lines, while columns remain unknown
after preprocessing because macro expansion changes their positions.
`c2fb_prototypes.bi` lowers collected function declarations for both SQLite
and generic headers. It owns function eligibility, outer and returned-callback
calling conventions, and generic-header function registration, and consumes
the shared parameter lowerer; the output backend formats the resulting
procedure bindings. `c2fb_callbacks.bi` lowers nested pointer/function chains
from the inside out and retains CDecl or StdCall for each callback layer.
Direct function prototypes whose return declarator repeats pointer/function
pairs use the same callback-chain builder as external callback objects.
`c2fb_body_lowering.bi` uses the same result type for body definitions, while
`c2fb_expr.bi` preserves postfix calls through callback-valued results.
SQLite-header, generic-header, and body collection now use the same scanner;
the SQLite header requests prototype-only collection through the shared
source-unit collector, and the generic record lowerer consumes record models
from that table. Body collection also captures block-local record models while each
function body is available. Body typedef alias, record-field, and procedure-
signature indexing consume the common table rather than rescanning source
text. Body conversion then makes a second streaming pass to lower function
definitions after the declaration and symbol indexes are ready. This keeps
complete function bodies out of the translation context while both passes use
the same source scanner. Declaration tokens remain available for semantic
indexing; each function body stays transient during lowering.
Record declarations also retain semicolon-delimited field source models and
their tokens. Generic layout validation and body record collection consume
these field models and token ranges for single- and multi-declarator fields.
Body record collection follows nested field models recursively, keeping its
owner-path mapping at the body lowering boundary and using the shared C record
prefix recognizer. Both lowerers use the same field-boundary collection;
comma-separated field tokens are reconstructed by
`BuildC2fbDeclaratorPartTokens`, and incomplete field models are rejected by the
owning lowering pass.
After matching source records to FreeBASIC layouts, the body index can create
a private generated `Type` or `Union` for a unique, unpacked source record
whose fields are supported scalar or pointer members, fixed one-dimensional
arrays, or nested records and unions with known size and layout. This includes
fixed arrays of union values. The generated layout is available to member and
`sizeof` lowering, but output includes it only when an accepted candidate uses
it. Bitfields, variable or multidimensional arrays, nested records without
known layouts, volatile members, and conditional or ambiguous definitions do
not take this path.
Function inventory and reconciliation live in `c2fb_function_index.bi`. The
inventory selects a profile of `c2fb_function_scanner.bi` that restores parser
state at conditional branches and omits body and record retention. It consumes
the same source-located function declaration models as body lowering, then
applies inventory duplicate and size-class policy before writing CSV. The
function-index adapter owns source selection, CSV lifecycle, and FreeBASIC
procedure reconciliation. All scanner entry points now take one typed request
containing input/root paths and a named `C2fbFunctionScannerProfile`. The
profile selects translation-unit, body-declaration, body-stream, inventory, or
prototype-only behavior; source-map mode and library pragma collection remain
explicit orthogonal options. The scanner derives its internal settings from
the profile; adapters no longer assemble combinations of Boolean collection
fields.

`C2fbDeclarationModel` retains source declarations and scanner facts. Generic
header names, support decisions, and lowered layouts live in the separate
`C2fbGenericRecordPlanModel`, indexed by the declaration table entry. This
keeps a target-specific record decision from changing the source model consumed
by SQLite headers, body indexing, and other lowering passes. The scanner and
declaration parser own writes to shared source entries; lowering reads them and
records mode-specific decisions in its owned context models. Record-plan
consumers check that each plan was prepared for the declaration index they use.
Scanned declarations, macro definitions and origins, body candidates, the
active source cursor, and diagnostics use `C2fbSourceLocationModel`. Path, line,
optional column, and system-header status now travel together through
collection and reporting.
Declarations use `C2fbSourceSpanModel` for their start and end locations; the
function inventory derives its line range from that span.
Passes that report an older declaration or macro supply its stored location to
`EmitC2fbSkippedAtLocation`; diagnostics about the current scan use the context
cursor.

`c2fb_types.bi` parses type syntax once into a target-independent model with a
base spelling, pointer depth, constness, tag kind, and unsupported-syntax flag.
`c2fb_type_resolution.bi` resolves that syntax into `C2fbResolvedTypeModel`,
keeping the FreeBASIC type, pointer count, constness, and resolution status
together. Status distinguishes invalid target or mapping options, unsupported
syntax, and a type with no mapping under the selected profile. Body,
prototype, and callback return lowering, along with shared parameter lowering,
consume this result directly, as do record, symbol, typedef, macro, and
expression lowering. Each pass checks the resolution status before using the
mapped type or its pointer and const qualifiers. Failure descriptions are
centralized and reused by body-return, prototype-return, and external-object
diagnostics.
`c2fb_parameters.bi` returns `C2fbParameterConversionResultModel` to body,
prototype, callback, symbol, and typedef lowering. Its status keeps an omitted
`void` parameter, a variadic marker, a converted declaration, and an unsupported
declaration distinct, so callers do not infer variadic behavior from a generic
negative return value.
The translation context carries a typed SQLite or generic target profile.
`c2fb_type_resolution.bi` dispatches that model by a typed mapping kind to the
generic-header mapper or the body mapper. The body mapper receives the active
SQLite or portable profile explicitly and owns scalar/type-name support checks.
`c2fb_sqlite_type_policy.bi` owns the SQLite-only body type-name classifier
used when generic profiles resolve port-specific aliases and records.
This keeps target-specific ABI
decisions out of C type syntax parsing and keeps mapping policy out of the
command driver. `C2fbTypeRecognitionStatusInContext` returns the strict
known-type resolution status from that same body resolver, so it does not
maintain a second support list beside the target mapper.
`c2fb_generic_policy.bi` owns generic type, symbol, string, array, include,
library, exclusion, and prefix policy. Policy-only helpers take
`C2fbGenericCPolicyModel` directly. `c2fb_generic_header_state.bi` owns header
aliases and alias-based storage and string mapping; those helpers take the
header-state model. String conversions that need both use
`C2fbGenericCTranslationStateModel`. The generic adapters interpret command
arguments and update those models instead of carrying separate option state.
`c2fb_expr.bi` owns C expression parsing and cast-shape recognition. Its
SQLite identifier policy, literal scanner, and sequence lowering are included
after the expression state models they consume; these are parser submodules,
not independent command dependencies.
`c2fb_sqlite_body_policy.bi` owns SQLite-specific identifier families, global
table/accessor mappings, and configuration-field access used by that parser.
`c2fb_parameters.bi` owns C parameter adjustment and conversion for prototypes,
callbacks, generic typedefs, body symbol indexing, and body procedures. These
passes share array-typedef extent and callback handling through the same helper.
Callback recognition returns `C2fbCallbackTypeResultModel`, separating
non-callback types from supported and recognized but unsupported callback
declarators. It uses the shared declarator model and lowers nested pointer to
function result chains from the inside out, retaining each layer's CDecl or
StdCall convention. Generic array typedef parsing returns
`C2fbGenericArrayTypedefResultModel`, separating non-array input, a supported
fixed array, and a recognized but unsupported array shape.

Generic-header preprocessing now feeds one declaration collection pass. The
collector receives source-unit state explicitly and stores plain declarations
and record declarations with source locations there. The typedef,
prototype, enum, and record output passes consume that collection instead of
rescanning the preprocessed header. Record-name preparation, layout validation,
forward-alias emission, field parsing, record-layout emission, and enum-member
collection/emission and enum expression lookup receive the translation
context explicitly. Generic typedef lowering receives the translation context
and project catalog. Prototype and external-object emission receive both
contexts from the generic-header path; prototype emission also receives them
from the SQLite-header path. Function-type aliases, array-size hints, string
overrides, name allocation, callback objects, and symbol recording in the
external-object path use those same contexts. Macro collection and expression
lowering consume the translation context, and the type, alias, function, and
replacement output passes do as well; type-macro mapping receives the project
catalog. The command runner creates local translation and project contexts for
each invocation and passes them into the selected adapter. Generic typedef
lowering now lives in `c2fb_generic_typedefs.bi` and consumes the shared
declarator, type, translation, and project models. The SQLite
public-header adapter now owns its ABI includes and declaration-file assembly
while using the shared collector and prototype output model. The SQLite
power-of-ten table adapter owns its source-specific table validation and emits
arrays through the common generated-file lifecycle.
SQLite numeric defines and generic-header macro collection share the
`C2fbMacroDefinitionModel` parser and source record for `#define`, function-like
`#define`, and `#undef`. Generic headers wrap that record in
`C2fbGenericHeaderMacroModel` for FreeBASIC names, expansion values, and
emission state. SQLite defines use `C2fbSqliteDefineModel` for normalized
integer expressions and conditional conflicts. The shared parser tokenizes a
replacement only when generic-header lowering requests it.
Body-file conversion, procedure construction, and structured-body validation
now receive both contexts explicitly. Statement, switch, block, return,
declaration, assignment, initializer, cast, and callback-output lowering also
use those contexts. `c2fb_body_statements.bi` owns the recursive statement and
control-flow parser; `c2fb_body_declarations.bi` owns local initialization;
`c2fb_body_lowering.bi` consumes both to assemble procedure candidates from
the shared scanner. Expression and C syntax handling stay in `c2fb_expr.bi`
and `c2fb_c_syntax.bi`. Expression lowering can continue a postfix call when a
callback invocation returns another callback type; shared callback signatures
provide the parameter conversions at each call layer.
Single-file, tree, generic-body, and preprocessed-tree body adapters also
receive contexts explicitly. `c2fb_simple_body_adapter.bi` owns the simple file
and tree orchestration, candidate filtering for existing and included-header
bodies, and submission of lowered candidates to the body output backend. The
CLI initializes command-local contexts; generic-header option parsing and
conversion consume them explicitly.

`c2fb_generic_header_adapter.bi` owns generic-header option parsing and its
declaration, macro-table, and optional selected-expansion preprocessor requests.
`c2fb_generic_body_adapter.bi` owns generic-body option parsing and file/tree
preprocessing. `c2fb_process.bi` executes typed
preprocessor requests, checks result files, removes partial outputs, and
provides shared shell-command and directory helpers. Both adapters pass typed
results into shared lowering and diagnostics; generic option state and lookup
remain in `c2fb_generic_policy.bi`.
`C2fbTranslationContext` owns the active ABI profile and connects source-unit,
symbol-table, body, and generic-C state. `C2fbSourceUnitStateModel` owns source
locations, diagnostics, declarations, and raw library pragma facts;
`C2fbSymbolTableStateModel` owns the shared C symbol bindings.
The symbol catalog keeps C identity, the selected FreeBASIC name, and identity
ambiguity at the shared level. `C2fbGenericHeaderSymbolBindingModel` owns header
types, procedure parameters, calling conventions, and object extents;
`C2fbBodySymbolModel` owns body call-name overrides, signatures, signature
ambiguity, definition availability, and runtime aliases. Generic-header
signature fields no longer share storage with body signature fields.
`body` groups body-only aliases, record metadata, and callback signatures;
`genericC.policy` groups generic C type/name overrides, replacements, and
caller options shared by header and body adapters. `genericC.header` owns
header aliases, record plans, enums, macros, and source-origin matches.
`c2fb_project_catalog.bi` builds
reusable FreeBASIC source indexes. A single `.bi` traversal collects callable names,
local declaration names, call signatures, and layout fields; a `.bas` traversal
collects callable and existing-procedure names plus call signatures.
`c2fb_body_call_signatures.bi` parses FreeBASIC declaration signatures and
resolves return/parameter types for C body expression lowering, while
`c2fb_symbols.bi` owns translation-unit C identities and body bindings.
`C2fbProjectCatalog` retains those indexes for a batch. The command runner
creates both objects locally for each invocation and discards them afterward.
`c2fb_names.bi` owns bounded open-addressed indexes for catalog membership,
call-signature lookup, and FreeBASIC record aliases. The ordered arrays remain
the source for output order; hash indexes avoid rescanning them while a large
`.bas` tree is collected. FreeBASIC name sets store lower-case keys to match
identifier lookup, while call-signature keys retain their parsed spelling and
verify a hit against the current signature before using it.
`C2fbReplacementRuleModel` is consumed by both generic-header macro lowering
and body expression lowering through `c2fb_replacements.bi`, so both paths use
the same token-normalized match key and replacement loader. The replacement
module also validates single-statement FreeBASIC replacements, extracts their
return expressions, and rewrites body-local names while protecting string
literals and member names. Its loader and lookup receive
`C2fbGenericCPolicyModel` directly rather than a full translation context.
`c2fb_diagnostics.bi` owns source-unit diagnostic reset, bounded collection,
code creation, and skip, rejection, and preprocessing reports. Its helpers
receive the translation context explicitly and delegate console or generated-
file formatting to the output backend. Fatal command errors use the same
diagnostic formatter without requiring a translation context and exit
immediately.
The common C type resolver also accepts both context objects explicitly and
passes them to the generic-header or body mapper. Conversion internals no
longer read context state implicitly; the CLI supplies local references at the
command boundary.
Simple body files and trees, generic-preprocessed body files and trees, and
SQLite preprocessed trees now pass `C2fbBodyTranslationOptions` into the same
body lowering entry point. The model carries the typed target profile, source
mapping and origin precision, assertion handling, and existing-body/dependency
policy; compiler and source selection details remain with the input adapter
that owns preprocessing.
The four simple file/tree modes normalize their paths, input shape, target
profile, and positional flags into `C2fbSimpleBodyRequestModel` before dispatching to the
shared file or tree converter. Generic-body compiler settings and lowering
options are held together by `C2fbGenericBodyInputModel`. Its input request
carries the paths and raw arguments, and selects the generic target profile at
construction. It also selects marker-aware source mapping because generic body
preprocessing retains compiler line markers. Option expansion and interpretation
stay with the generic-body adapter. Generic-header paths and expanded arguments use
`C2fbGenericHeaderInputModel`. The SQLite preprocessed tree and explicit
file-list modes pass their paths, compiler, feature defines, source selection,
body type-map arguments, and body policy together in
`C2fbPreprocessedBodyRequestModel`; a typed input kind distinguishes directory
scanning from an explicit file list. Type maps use the shared body policy in
SQLite and generic modes, so the same C alias can resolve to a port-owned
FreeBASIC layout without adding another target-specific type rule.
Positional and named boolean values use the same validator. SQLite's `-P` preprocessing
strips line markers, so the adapter carries the selected original source path
through `sourceLabel` for candidate comments and diagnostics. It also marks the
origin as path-only. The shared scanner then omits flattened `.i` line and column
offsets instead of presenting them as coordinates in the original C file.
Generic-header preprocessing, generic-body preprocessing, and the SQLite
preprocessed-tree mode now submit a `C2fbPreprocessorRequestModel` to the
`c2fb_process.bi` executor. Each input adapter still selects its compiler
switches, while the executor adds quoted input/output paths, returns a
`C2fbPreprocessorResultModel`, checks the compiler result, and removes partial
output on failure. Every mode records preprocessing failures through the shared
source-located diagnostic model while keeping its own abort or continue policy.
`c2fb_sqlite_preprocessed_adapter.bi` owns SQLite support-header preparation,
engine-source selection, feature-define validation, assertion-suppression
policy, and preprocessed-tree orchestration. It sends each source through the
shared preprocessor result and body-candidate pipeline. The input
adapter writes `sqlite3.h`, `sqlite_cfg.h`, and the optional assertion header
through the shared generated-file lifecycle; generation of SQLite's pragma
header remains an external Tcl input step. `c2fb_source_files.bi` owns bounded
file-set growth and directory enumeration; adapters select extensions and
exclusion policy. `c2fb_file_input.bi` owns file presence checks alongside
text and binary input, while `c2fb_process.bi` owns process execution and
preprocessor cleanup.
Generic-header and generic-body adapters expand response files into the same
bounded `C2fbArgumentListModel`; compiler selection and argument quoting also
use `c2fb_arguments.bi`. Each adapter still interprets its own C2FB options and
decides which compiler switches to forward. Simple and generic body trees,
preprocessed engine inputs, function inventory, and FreeBASIC project-index
passes retain selected filenames in one bounded `C2fbSourceFileSetModel`.
Their adapters choose extensions and whether test-support and shell files are
included; directory enumeration and list growth are shared. Explicit
preprocessed file lists keep their path validation and output-collision
checks.
Generic-header bindings and body procedures now share one `C2fbSymbolModel`
table in `C2fbSymbolTableStateModel`. Header and body lookup use the same
source-name index, while ownership flags keep each lowering pass from reading
the other pass's signature metadata. This gives name identity, FreeBASIC name,
C alias, and symbol kind one shared source of truth.
Body symbol indexing, procedure and alias lookup, candidate dependency
filtering, and declaration emission also accept the translation context and
project catalog. Callback-table lifecycle, recursive callback recognition, and
parameter lowering do too. The body symbol and callback modules no longer
read context state implicitly. The expression parser stores explicit
context pointers in its parse state and passes them to field, callback, and
type lowering. Body-replacement loading and lookup also take the translation
context. FreeBASIC layout indexing and its lookup,
record mapping, and size checks also accept the project catalog and active
profile explicitly. C record field collection, recursive parsing, nested
binding, field lookup, and field type resolution also accept those contexts;
the record, expression, and command callers pass their command-local instances.
The expression and replacement-rule modules no longer read the shared
instances directly. The command boundary passes its local instances in; generic
header external-object, macro collection, and macro output passes consume
them explicitly. Body-file conversion, procedure construction, structured
statement lowering, candidate indexing, and candidate declaration/include
output also consume contexts explicitly. Body tree and preprocessed-tree
orchestration, SQLite header conversion, numeric define conversion, and
generic-header option parsing also receive contexts. The command runner owns
the per-invocation contexts and initial diagnostic reset.
`C2fbDiagnosticModel` records severity, code, source path, line, and message for
generic-header declaration, record, macro, and external-object skips,
unsupported function prototypes, body candidate rejections, and other emitted
skip comments. Body lowering keeps the first detailed parser failure in
`SimpleBodyContext`; the structured-body boundary sends it through the common
diagnostic reporter once, with the active source location. Lower-level body
parsers no longer print rejection messages directly. Candidate output keeps its
summary skip comment and adds bounded, single-line detail comments for the
stored body diagnostics. Console output retains the detailed failure once
instead of printing a parser message followed by a second generic rejection.
Input paths and available line numbers are recorded. Generic-header
preprocessing retains line markers for declaration and record locations, and a
`-dD` pass maps final active macro definitions back to their defining files
when the normalized definitions match. Continued definitions are joined before
origin matching; compiler built-ins can still lack a source origin. Nested
passes now carry skip totals in
`C2fbConversionSummaryModel` rather than raw `Long` parameters. Defines and
body-candidate passes also store their converted totals there, and defines
keep ambiguity totals in `sqliteDefines`. Header and generic-header passes
share the root converted/skipped totals; generic-header external-object,
record, macro-category, and replacement-rule totals are grouped in
`genericHeader`. Output-name and source-file counts remain local to their
owning passes. Preprocessed-tree
success/failure totals and function-reconciliation matches stay in their
adapters because neither count is accumulated by translation passes.

`c2fb_output.bi` owns procedure, external-object, type-alias, record-layout,
scalar-constant, initialized integer-array, macro, and diagnostic output models. Each
binding writer submits a typed `C2fbOutputItemModel` to one dispatcher, which
selects the type-specific formatter. Skip comments use a distinct output-item
kind, keeping their comment prefix out of the structured diagnostic model.
Generic C prototypes, function typedef
aliases, macro aliases, body runtime imports, body candidate declarations, and
candidate definitions use the procedure model. The SQLite API-table helper uses
it for placeholder function declarations. Generic scalar, fixed-array, and
unsized-array bindings use the object model. Generic record aliases and layouts
use the type-alias and record models. Generic enum members and integer `Const`
definitions use the constant model. SQLite's power-of-ten tables use the
integer-array model for initialized `ULong` arrays. Generic and body paths use
the macro model for object-like, function-like, string, and replacement macros. Macro parsing
and diagnostics remain specialized; guard names and placement stay with their
owning output paths, while the shared backend writes paired guard directives.
`C2fbBodyCandidateFileModel` and `c2fb_body_output.bi` now
own candidate-file preambles, ABI aliases, callback and existing declarations,
candidate procedures, project-header selection, and diagnostic comments. It
reads generated SQLite API declaration files and adds SQLite support headers
only under the SQLite target profile; discovered project headers remain
available to generic targets. This separates body output policy from source
collection, lowering, and candidate selection.
Generic-header record validation builds each `C2fbRecordBindingModel` once in
the generic record plan; file emission consumes those lowered models without
parsing record bodies again. The source declaration keeps its scanner-owned
support facts unchanged.
All generated FreeBASIC files now use the shared bounded comment model,
file-handle lifecycle, and line sink. Generated-file preambles use an ordered
model with typed include-once, library, undefinition, comment, and blank entry
kinds. The output backend validates and formats those entries;
each pass still selects target-specific inputs and ordering. The same backend
tracks paired include-guard lifecycles, while each pass selects guard names and
placement. Binding order and mode-specific content remain with their owning
passes, while the tagged item backend formats modeled bindings and diagnostics.
`c2fb_generated_file_output.bi` owns shared file handles, comments, preambles,
include guards, and text/line output. It writes to a unique sibling staging
path and keeps an existing destination until the new file is complete. A
stable backup sidecar allows the next open to recover if publication is
interrupted between the two renames. It registers active outputs for fatal
cleanup, records write and close failures in the output model, and removes
failed staging files before adapters report success. A failed output check
aborts the rest of the active output set. The API-table generator uses an
explicit abort for validation failures after opening its output. If the old
file cannot be restored after a failed publish, output diagnostics include the
backup sidecar path for manual recovery.
`c2fb_csv_output.bi` owns bounded CSV row parsing, quoting, and field formatting
on that shared file lifecycle.
Passes and binding writers carry `C2fbGeneratedFileOutputModel` by reference;
the lifecycle module alone opens, closes, and writes through the raw file handle.
Function inventory output now uses a typed record model, and reconciliation
CSV uses the bounded row model. Both share one quoting/writing backend, so the
passes supply field values and quote policy rather than assembling CSV syntax
directly. The CSV backend parses reconciliation input into that same bounded
row model, rejects malformed quoting before rewriting, quotes values that need
it, and uses the shared generated-file open/close lifecycle for both reports. The SQLite API
table helper also uses this parser to read the porting-function ledger instead
of maintaining a second CSV field parser.

Ordinary and function declaration models retain token strings in the common
translation-unit declaration table while preserving source text for diagnostics
and specialized lowering. Body typedef-alias indexing and generic typedef
lowering consume those tokens; multi-declarator typedefs split by token range
while respecting nested declarators. Record field source models keep their
tokens for generic and body lowering. Generic type and alias classification
use declaration tokens, and function-macro parameter parsing uses cached macro
tokens, while macro
replacement expressions and body statement expressions still operate on raw
source text.

## Maintaining the pipeline

C2FB keeps mode policy at the adapters and shared syntax/lowering in common
passes. New work should preserve these boundaries:

- A command starts as a typed request in `c2fb_model.bi`. Normalize command
  syntax in `c2fb_inputs.bi`; keep `c2fb.bas` limited to initializing contexts
  and dispatching the request.
- C declaration collection uses `C2fbDeclarationScanRequestModel` and the named
  translation-unit, body-stream, or inventory builders. Add declaration syntax
  to the shared scanner and declarator models so headers, inventories, and body
  indexing see the same source identity and category.
- Keep scanned declarations as source facts after collection. Store target-side
  names, support decisions, and layouts in the owning pass state, such as
  `genericC.header.recordPlans`; do not add those results back onto
  `C2fbDeclarationModel`.
- Keep C symbol identity and the selected FreeBASIC name shared, but add new
  header and body facts to their corresponding nested symbol models. Body-only
  call aliases and signature conflicts belong to `C2fbBodySymbolModel`.
- Encode inventory source selection with `C2fbFunctionIndexSourceScope`; keep
  CLI spelling in the input adapter and pass only the normalized scope onward.
- Type syntax is parsed once into `C2fbCTypeModel`. Put ABI choices in the
  mapper selected by `C2fbTypeMappingKind`, and carry SQLite versus generic
  policy as `C2fbTargetProfile` in the translation context and body request.
- Shared prototype, callback, and parameter lowerers take the named
  `C2fbTypeMappingKind` so generic-header behavior stays distinct from body
  mapping without raw numeric mode flags.
- Pointer type resolution carries `C2fbPointerMappingPolicy` separately from
  the body-versus-header mapping kind; use its named preserve or opaque value
  instead of a Boolean pointer flag.
- Body input adapters set `C2fbBodyTranslationOptions` and call the shared body
  file/tree conversion. Keep preprocessing and file selection in adapters;
  put shared statement and expression behavior in the common lowerers.
- Generic-header macro collection, lowering, and emission are separate passes.
  Use `C2fbGenericHeaderDeclarationPassKind` for pass ordering; keep record
  layouts in the record pass and plain external bindings in the declaration
  pass.
- Lowerers submit binding and diagnostic models to `c2fb_output.bi`. Keep
  syntax and policy out of the formatter, and keep emitted file lifecycle and
  CSV syntax in their respective output paths.
- Pass output APIs take `C2fbGeneratedFileOutputModel` by reference. Keep the
  raw file handle inside `c2fb_generated_file_output.bi` so nested passes share
  one checked destination state.
- External compiler execution uses `C2fbPreprocessorRequestModel` and
  `c2fb_process.bi`. Adapters select compiler flags; the executor owns quoting,
  status checks, and failed-output cleanup.
- When adding an included module, update the Makefile dependency closure. The
  converter and API-table helper each have independent include graphs.

A successful build proves the composed FreeBASIC source still compiles. It does
not by itself prove translation behavior; use the focused C2FB behavior tests
when validating a behavior change.

`check_candidates.py` records each compile result with its candidate file,
procedure, reachable helper list, status, and diagnostics. Its dependency scan
masks string literals and comments before matching calls, and it reports
candidate files with no new bodies so empty coverage is visible in both report
modes. Candidate procedure comments preserve their C source path and line, so
the compiler report can identify the source declaration behind a failed
FreeBASIC body. Aggregated function, source-origin, and helper columns encode
their values as JSON within CSV rows.

The current `tests/test_c2fb.py` harness exercises `translate-simple`,
`translate-preprocessed-tree`, SQLite declaration, define, floating-point
table, function-index, reconciliation, and API-table generation, as well as
the generic-header and generic-body adapters. It also compiles generated
bindings and compares selected body candidates with C behavior on FreeBASIC's
native and GCC backends. These tests cover representative inputs; they do not
prove semantic or ABI equivalence for every C program or target profile.
