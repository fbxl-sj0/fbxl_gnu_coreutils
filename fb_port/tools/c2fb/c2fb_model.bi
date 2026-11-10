/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_model.bi

    Purpose:

        Define the shared translation models and own per-input and project
        state used by C2FB.

    Responsibilities:

        - Record declarator names, token spans, and binding operators.
        - Record target-independent C types and resolved FreeBASIC type shapes.
        - Preserve type-resolution status with the mapped type and qualifiers.
        - Select whether unknown type names may use target fallback mappings.
        - Distinguish omitted, variadic, converted, and unsupported parameters.
        - Distinguish non-array typedefs from converted and unsupported arrays.
        - Distinguish non-callback types from converted and unsupported callbacks.
        - Retain scanned declaration syntax and source-origin facts.
        - Keep declaration start and end origins together as source spans.
        - Track when preprocessing preserves a path but removes C coordinates.
        - Give header, typedef, and callback conversion one parse result.
        - Retain source paths and line spans on scanned declarations.
        - Carry shared body-lowering settings across file and tree adapters.
        - Represent normalized simple-body, generic-body, and preprocessed-tree
          input requests.
        - Describe compiler input and output paths for C preprocessing.
        - Return structured compiler and output-file status for preprocessing.
        - Carry active source path, line, and column in one location model.
        - Represent shared C macro directive syntax, replacement text, and
          optional replacement tokens.
        - Carry source paths and explicit collection policy into the shared C
          declaration scanner.
        - Keep generic-header macro lowering and SQLite define state in
          separate models built from shared macro definitions.
        - Group body-only and generic-C translation state by owner.
        - Store replacement rules shared by generic-header macros and bodies.
        - Retain expanded command arguments in a bounded list model.
        - Route mode-specific request models through one command model.
        - Type the SQLite extension API table generator's request and result.
        - Type command and shared-symbol discriminants with named enums.
        - Retain selected C source files as a bounded file-set model.
        - Own source-specific symbols, aliases, overrides, records, and macros.
        - Keep generic source filters and their audit state in policy.
        - Keep generic declaration guard patterns and their audit state in policy.
        - Store ordered generic-header declaration moves and their outcomes.
        - Track requested typedef expansion names and their matches.
        - Track selected macro expansion patterns and their outcomes.
        - Track opt-in integer-macro assumptions and their matches.
        - Track selected generic forward declaration patterns and their matches.
        - Store generic-header inline body emission policy.
        - Keep generic-header and body facts separate within shared C symbols.
        - Retain typed external C objects used by generic body candidates.
        - Store generic-header record decisions separately from scanned syntax.
        - Represent diagnostics and lowered artifacts shared by passes and
          output backends.
        - Carry conversion totals across nested lowering passes.
        - Keep reusable FreeBASIC source indexes separate from C input state.

    This file intentionally does NOT contain:

        - Target type mappings or FreeBASIC output formatting.
        - Input scanning, preprocessing, or function-body translation.
'/

#include once "c2fb_limits.bi"

Enum C2fbDeclaratorOperatorKind
    C2FB_DECLARATOR_INVALID = 0
    C2FB_DECLARATOR_POINTER = 1
    C2FB_DECLARATOR_ARRAY = 2
    C2FB_DECLARATOR_FUNCTION = 3
End Enum
Enum C2fbDeclarationKind
    C2FB_DECLARATION_PLAIN = 0
    C2FB_DECLARATION_RECORD = 1
    C2FB_DECLARATION_FUNCTION = 2
End Enum
Enum C2fbRecordKind
    C2FB_RECORD_KIND_NONE = 0
    C2FB_RECORD_STRUCT = 1
    C2FB_RECORD_UNION = 2
    C2FB_RECORD_ENUM = 3
End Enum
Enum C2fbGenericHeaderDeclarationPassKind
    C2FB_GENERIC_HEADER_PASS_INVALID = 0
    C2FB_GENERIC_HEADER_PASS_INDEX_TYPEDEFS = 1
    C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS = 2
    C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS_AFTER_RECORDS = 3
    C2FB_GENERIC_HEADER_PASS_EMIT_DECLARATIONS = 4
End Enum
Enum C2fbTargetProfile
    C2FB_TARGET_INVALID = 0
    C2FB_TARGET_SQLITE = 1
    C2FB_TARGET_GENERIC = 2
End Enum
Enum C2fbSourceMapMode
    C2FB_SOURCE_MAP_DISABLED = 0
    C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS = 1
End Enum

' Coordinates are omitted when preprocessing removes the original line mapping.
Enum C2fbSourceOriginPrecision
    C2FB_SOURCE_ORIGIN_LINES_AVAILABLE = 0
    C2FB_SOURCE_ORIGIN_PATH_ONLY = 1
End Enum
Enum C2fbBodyInputShape
    C2FB_BODY_INPUT_FILE = 0
    C2FB_BODY_INPUT_TREE = 1
End Enum

Enum C2fbPreprocessedInputKind
    C2FB_PREPROCESSED_INPUT_INVALID = 0
    C2FB_PREPROCESSED_INPUT_TREE = 1
    C2FB_PREPROCESSED_INPUT_FILE_LIST = 2
End Enum

' Shared prototype and callback lowerers use this instead of a raw ABI-mode flag.
Enum C2fbTypeMappingKind
    C2FB_TYPE_MAPPING_BODY = 0
    C2FB_TYPE_MAPPING_GENERIC_HEADER = -1
End Enum

' Select whether pointer mappings retain declared detail or use opaque pointers.
Enum C2fbPointerMappingPolicy
    C2FB_POINTER_MAPPING_PRESERVE = 0
    C2FB_POINTER_MAPPING_OPAQUE = -1
End Enum

' Control whether unresolved C names may use the opaque or C-int fallback.
Enum C2fbTypeRecognitionPolicy
    C2FB_TYPE_RECOGNITION_ALLOW_FALLBACK = 0
    C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY = -1
End Enum

' Type resolution preserves why a C type could not be mapped for diagnostics.
Enum C2fbTypeResolutionStatus
    C2FB_TYPE_RESOLUTION_INVALID = 0
    C2FB_TYPE_RESOLUTION_RESOLVED = 1
    C2FB_TYPE_RESOLUTION_INVALID_TARGET = 2
    C2FB_TYPE_RESOLUTION_INVALID_MAPPING = 3
    C2FB_TYPE_RESOLUTION_INVALID_OPTIONS = 4
    C2FB_TYPE_RESOLUTION_UNSUPPORTED_SYNTAX = 5
    C2FB_TYPE_RESOLUTION_UNMAPPED_TYPE = 6
    C2FB_TYPE_RESOLUTION_UNSUPPORTED_POINTER_DEPTH = 7
End Enum

' Preserve omission, ellipsis, and unsupported-declaration outcomes separately.
Enum C2fbParameterConversionStatus
    C2FB_PARAMETER_CONVERSION_INVALID = 0
    C2FB_PARAMETER_CONVERSION_OMITTED = 1
    C2FB_PARAMETER_CONVERSION_CONVERTED = 2
    C2FB_PARAMETER_CONVERSION_VARIADIC = 3
    C2FB_PARAMETER_CONVERSION_UNSUPPORTED = 4
End Enum

Private Const C2FB_C_CHARACTER_NONE As Long = 0
Private Const C2FB_C_CHARACTER_CHAR As Long = 1
Private Const C2FB_C_CHARACTER_SIGNED As Long = 2
Private Const C2FB_C_CHARACTER_UNSIGNED As Long = 3
Private Const C2FB_C_CHARACTER_WIDE As Long = 4

Enum C2fbGenericArrayTypedefStatus
    C2FB_GENERIC_ARRAY_TYPEDEF_INVALID = 0
    C2FB_GENERIC_ARRAY_TYPEDEF_NOT_APPLICABLE = 1
    C2FB_GENERIC_ARRAY_TYPEDEF_CONVERTED = 2
    C2FB_GENERIC_ARRAY_TYPEDEF_UNSUPPORTED = 3
End Enum

Enum C2fbCallbackTypeStatus
    C2FB_CALLBACK_TYPE_INVALID = 0
    C2FB_CALLBACK_TYPE_NOT_CALLBACK = 1
    C2FB_CALLBACK_TYPE_CONVERTED = 2
    C2FB_CALLBACK_TYPE_UNSUPPORTED = 3
End Enum

Enum C2fbFunctionScannerProfile
    C2FB_FUNCTION_SCAN_INVALID = 0
    C2FB_FUNCTION_SCAN_TRANSLATION_UNIT = 1
    C2FB_FUNCTION_SCAN_BODY_DECLARATIONS = 2
    C2FB_FUNCTION_SCAN_BODY_STREAM = 3
    C2FB_FUNCTION_SCAN_INVENTORY = 4
    C2FB_FUNCTION_SCAN_PROTOTYPES_ONLY = 5
End Enum

Enum C2fbFunctionIndexSourceScope
    C2FB_FUNCTION_INDEX_SCOPE_INVALID = 0
    C2FB_FUNCTION_INDEX_SCOPE_C_ONLY = 1
    C2FB_FUNCTION_INDEX_SCOPE_C_AND_HEADERS = 2
End Enum

Enum C2fbLibraryPragmaCollectionMode
    C2FB_LIBRARY_PRAGMAS_IGNORE = 0
    C2FB_LIBRARY_PRAGMAS_COLLECT = 1
End Enum

' Command identifiers are kept beside the request model consumed by the driver.
Enum C2fbCommandKind
    C2FB_COMMAND_INVALID = 0
    C2FB_COMMAND_DEFINES = 1
    C2FB_COMMAND_SIMPLE_BODY = 2
    C2FB_COMMAND_GENERIC_BODY = 3
    C2FB_COMMAND_PREPROCESSED_BODY = 4
    C2FB_COMMAND_FP_TABLES = 5
    C2FB_COMMAND_FUNCTION_INDEX = 6
    C2FB_COMMAND_FUNCTION_RECONCILE = 7
    C2FB_COMMAND_GENERIC_HEADER = 8
    C2FB_COMMAND_HEADER = 9
    C2FB_COMMAND_API_ROUTINES = 10
End Enum

Private Type C2fbDeclaratorModel
    name As String
    bindingOrder As String
    ' Function suffix token positions are encoded in bindingOrder order.
    functionOpenPositions As String
    nameTokenIndex As Long
    firstFunctionOpenToken As Long
    firstToken As Long
    nextToken As Long
    operatorCount As Long
    operatorKind(0 To MAX_TYPE_WORDS - 1) As C2fbDeclaratorOperatorKind
End Type

Private Type C2fbCTypeModel
    baseName As String
    pointerDepth As Long
    isConst As Long
    ' Bit zero is the base type; each higher bit is one pointer level.
    volatileMask As Long
    isEnum As Long
    isStruct As Long
    isUnion As Long
    hasUnsupportedSyntax As Long
End Type

Private Type C2fbResolvedTypeModel
    status As C2fbTypeResolutionStatus
    freeBasicType As String
    pointerCount As Long
    isConst As Long
    volatileMask As Long
End Type

Private Type C2fbParameterConversionResultModel
    status As C2fbParameterConversionStatus
    sourceName As String
    argumentName As String
    freeBasicType As String
    freeBasicDeclaration As String
    defaultValue As String
    isByRef As Long
End Type

Private Type C2fbGenericArrayTypedefResultModel
    status As C2fbGenericArrayTypedefStatus
    aliasName As String
    sourceElementType As String
    characterKind As Long
    elementType As String
    arrayCount As Long
    arrayBounds As String
End Type

Private Type C2fbCallbackTypeResultModel
    status As C2fbCallbackTypeStatus
    callbackName As String
    freeBasicType As String
    pointerDepth As Long
End Type

Private Type C2fbFunctionDeclarationModel
    declarator As C2fbDeclaratorModel
    declaratorStartToken As Long
    specifierEndToken As Long
End Type

Private Type C2fbBodyTranslationOptions
    fbSourceDirectory As String
    fbSourceRecursive As Long
    keepUnresolvedDependencies As Long
    includeExistingBodies As Long
    includeHeaderInlineBodies As Long
    includeHeaderBodyNames As String
    includeIncludedCSourceBodies As Long
    includeGlobalDefinitions As Long
    assertionsStripped As Long
    profileTimings As Long
    assumeSingleThreadedAtomics As Long
    atomicMutexRuntime As Long
    assumeZeroStaticAggregates As Long
    targetProfile As C2fbTargetProfile
    sourceLabel As String
    sourceMapMode As C2fbSourceMapMode
    sourceOriginPrecision As C2fbSourceOriginPrecision
End Type

Private Type C2fbArgumentListModel
    values(Any) As String
    itemCount As Long
    capacity As Long
End Type

' Direct and generic body commands share their source selection and policy.
Private Type C2fbBodyTranslationRequestModel
    sourcePath As String
    outputPath As String
    inputShape As C2fbBodyInputShape
    translationOptions As C2fbBodyTranslationOptions
End Type

' One selected or preprocessed C file submitted to the body pipeline.
Private Type C2fbBodyFileTranslationRequestModel
    inputPath As String
    outputPath As String
    translationOptions As C2fbBodyTranslationOptions
End Type

Private Type C2fbGenericBodyInputModel
    bodyRequest As C2fbBodyTranslationRequestModel
    argumentList As C2fbArgumentListModel
    compilerName As String
    compilerOptions As String
End Type

Private Type C2fbFileConversionRequestModel
    inputPath As String
    outputPath As String
End Type

Private Type C2fbGenericHeaderInputModel
    fileRequest As C2fbFileConversionRequestModel
    argumentList As C2fbArgumentListModel
End Type

Private Type C2fbSourceFileSetModel
    names(Any) As String
    itemCount As Long
    capacity As Long
End Type

Private Type C2fbPreprocessedBodyRequestModel
    inputKind As C2fbPreprocessedInputKind
    sourceDirectory As String
    generatedIncludeDirectory As String
    outputDirectory As String
    compilerName As String
    threadSafe As Long
    featureDefines As String
    bodyArguments As C2fbArgumentListModel
    selectedSourceFiles As C2fbSourceFileSetModel
    translationOptions As C2fbBodyTranslationOptions
End Type

Private Type C2fbFunctionIndexRequestModel
    sourceDirectory As String
    outputPath As String
    sourceScope As C2fbFunctionIndexSourceScope
End Type

Private Type C2fbFunctionReconcileRequestModel
    csvPath As String
    fbDirectory As String
End Type

Private Type C2fbApiRoutinesRequestModel
    preprocessedInputPath As String
    functionLedgerPath As String
    ownerModulePath As String
    outputPath As String
End Type

Private Type C2fbApiRoutinesResultModel
    entryCount As Long
    portedCount As Long
End Type

Private Type C2fbFunctionScannerOptionsModel
    sourceMapMode As C2fbSourceMapMode
    sourceOriginPrecision As C2fbSourceOriginPrecision
    collectLibraryPragmas As C2fbLibraryPragmaCollectionMode
    collectHeaderInlineBodies As Long
    includeHeaderBodyNames As String
    collectIncludedCSourceBodies As Long
End Type

' Internal scanner flags are derived from the request's named profile.
Private Type C2fbFunctionScannerSettingsModel
    sourceMapMode As C2fbSourceMapMode
    sourceOriginPrecision As C2fbSourceOriginPrecision
    collectLibraryPragmas As C2fbLibraryPragmaCollectionMode
    collectFunctionDefinitions As Long
    collectRecordModels As Long
    retainFunctionBodies As Long
    collectHeaderInlineBodies As Long
    includeHeaderBodyNames As String
    collectIncludedCSourceBodies As Long
    recognizeCLinkageBlocks As Long
    resetConditionalBranches As Long
End Type

Private Type C2fbDeclarationScanRequestModel
    inputPath As String
    rootSourcePath As String
    profile As C2fbFunctionScannerProfile
    options As C2fbFunctionScannerOptionsModel
    cppMode As Long
End Type

Private Type C2fbCommandModel
    kind As C2fbCommandKind
    fileRequest As C2fbFileConversionRequestModel
    bodyRequest As C2fbBodyTranslationRequestModel
    genericBodyRequest As C2fbGenericBodyInputModel
    preprocessedBodyRequest As C2fbPreprocessedBodyRequestModel
    genericHeaderRequest As C2fbGenericHeaderInputModel
    functionIndexRequest As C2fbFunctionIndexRequestModel
    functionReconcileRequest As C2fbFunctionReconcileRequestModel
    apiRoutinesRequest As C2fbApiRoutinesRequestModel
End Type

Private Type C2fbPreprocessorRequestModel
    compilerName As String
    compilerOptions As String
    inputPath As String
    outputPath As String
End Type

Private Type C2fbPreprocessorResultModel
    inputPath As String
    outputPath As String
    compilerStatus As Long
    failureReason As String
End Type

Private Type C2fbPreprocessorEnvironmentModel
    sourceDirectory As String
    includeDirectory As String
    assertionsStripped As Long
    assertionsRestored As Long
End Type

' Keep file and coordinate together as source origins cross collection passes.
Private Type C2fbSourceLocationModel
    path As String
    line As Long
    column As Long
    isSystemHeader As Long
End Type

' Declaration spans retain both source endpoints, even when a mode lacks one.
Private Type C2fbSourceSpanModel
    startLocation As C2fbSourceLocationModel
    endLocation As C2fbSourceLocationModel
End Type

Private Type C2fbTokenRangeModel
    firstToken As Long
    lastToken As Long
End Type

Private Type C2fbRecordFieldSourceModel
    ' Preserve the field text for diagnostics and the token owner for lowering.
    text As String
    tokens(Any) As String
    tokenCount As Long
End Type

Private Type C2fbMacroDefinitionModel
    directive As String
    sourceName As String
    rawValue As String
    sourceLocation As C2fbSourceLocationModel
    inputOrder As LongInt
    tokens(Any) As String
    tokenCount As Long
    functionLike As Long
    continued As Long
End Type

' Keep FreeBASIC lowering decisions in the generic-header translation context.
Private Type C2fbGenericHeaderMacroModel
    definition As C2fbMacroDefinitionModel
    ' Keep the input replacement list for caller rules after optional expansion.
    sourceRawValue As String
    resolvedValue As String
    freeBasicName As String
    active As Long
    privateName As Long
    emitted As Long
    isString As Long
    tokenConversionFailed As Long
End Type

' Keep SQLite's integer conversion and conflict state out of generic macros.
Private Type C2fbSqliteDefineModel
    definition As C2fbMacroDefinitionModel
    integerExpression As String
    ambiguous As Long
End Type

Private Type C2fbDeclarationModel
    text As String
    sourceName As String
    linkName As String
    sourceSpan As C2fbSourceSpanModel
    inputOrder As LongInt
    removeFromGenericHeader As Long
    recordPrefix As String
    recordBody As String
    recordTail As String
    recordTag As String
    recordAlias As String
    removedDeclarators(Any) As String
    removedDeclaratorCount As Long
    removedEnumMembers(Any) As String
    removedEnumMemberCount As Long
    recordFields(Any) As C2fbRecordFieldSourceModel
    recordFieldCount As Long
    recordFieldsComplete As Long
    ' Later body passes retry enum expressions until their dependencies resolve.
    enumValuesNeedResolution As Long
    functionDeclaration As C2fbFunctionDeclarationModel
    tokens(Any) As String
    tokenCount As Long
    entryKind As C2fbDeclarationKind
    recordKind As C2fbRecordKind
    isTypedef As Long
    isPacked As Long
    packValue As Long
    recordAlignment As Long
    typedefAlignment As Long
    hasNestedRecord As Long
    unsupportedAssemblyName As Long
    unsupported As Long
    isFunctionDefinition As Long
    isNoReturn As Long
    isBlockLocal As Long
    isConditional As Long
    hasDirectives As Long
    isHeaderBody As Long
End Type

' These lowered models cross from translation passes into output adapters.
Private Type C2fbProcedureBindingModel
    freeBasicName As String
    cName As String
    linkName As String
    returnType As String
    parameterList As String
    callingConvention As String
    isWindowsMS As Long
    isSub As Long
    isPrivate As Long
End Type

Private Type C2fbBodyCandidateModel
    name As String
    source As String
    procedureBinding As C2fbProcedureBindingModel
    sourceLocation As C2fbSourceLocationModel
    diagnosticStart As Long
    diagnosticCount As Long
    duplicate As Long
    isHeaderBody As Long
    isHeaderInlineBody As Long
    isHeaderRequired As Long
    skipMessage As String
End Type

Private Type C2fbRecordFieldBindingModel
    name As String
    fieldType As String
    alignmentStorageType As String
    arrayCount As Long
    arrayBounds As String
End Type

Enum C2fbRecordBindingItemKind
    C2FB_RECORD_BINDING_ITEM_INVALID = 0
    C2FB_RECORD_BINDING_ITEM_FIELD = 1
    C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN = 2
    C2FB_RECORD_BINDING_ITEM_ANONYMOUS_END = 3
    C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY = 4
End Enum

' A record is a linear field/block stream so anonymous C aggregates keep ABI nesting.
Private Type C2fbRecordBindingItemModel
    kind As C2fbRecordBindingItemKind
    isUnion As Long
    packValue As Long
    isBitField As Long
    isArraySizeHinted As Long
    bitWidth As Long
    name As String
    sourceName As String
    fieldType As String
    alignmentStorageType As String
    arrayCount As Long
    arrayBounds As String
    zeroArrayAccessorName As String
    zeroArrayStorageName As String
    zeroArrayPreviousFieldName As String
    zeroArrayPreviousArrayCount As Long
End Type

Private Type C2fbRecordBindingModel
    freeBasicName As String
    isUnion As Long
    isPacked As Long
    packValue As Long
    alignmentValue As Long
    naturalAlignmentValue As Long
    fields(Any) As C2fbRecordFieldBindingModel
    fieldCount As Long
    items(Any) As C2fbRecordBindingItemModel
    itemCount As Long
End Type

Enum C2fbDiagnosticSeverity
    C2FB_DIAGNOSTIC_SEVERITY_INVALID = 0
    C2FB_DIAGNOSTIC_SEVERITY_WARNING = 1
    C2FB_DIAGNOSTIC_SEVERITY_ERROR = 2
End Enum

Private Type C2fbDiagnosticModel
    severity As C2fbDiagnosticSeverity
    code As String
    location As C2fbSourceLocationModel
    message As String
End Type

Private Type C2fbSQLiteDefineSummaryModel
    ambiguousCount As Long
End Type

Private Type C2fbGenericHeaderSummaryModel
    externalObjectCount As Long
    moduleStaticObjectCount As Long
    recordLayoutCount As Long
    integerMacroCount As Long
    floatingMacroCount As Long
    pointerCastMacroCount As Long
    typeMacroCount As Long
    stringMacroCount As Long
    aliasMacroCount As Long
    functionMacroCount As Long
    callMacroCount As Long
    tokenSequenceMacroCount As Long
    initializerMacroCount As Long
    statementMacroCount As Long
    emptyMacroCount As Long
    tokenMacroConversionCount As Long
    customMacroReplacementCount As Long
End Type

' Passes accumulate common and owner-specific totals; adapters report them.
Private Type C2fbConversionSummaryModel
    convertedCount As Long
    skippedCount As Long
    sqliteDefines As C2fbSQLiteDefineSummaryModel
    genericHeader As C2fbGenericHeaderSummaryModel
End Type

' Diagnostics and the active source cursor share one translation-state owner.
Private Type C2fbDiagnosticStateModel
    currentSourceLocation As C2fbSourceLocationModel
    diagnostics(Any) As C2fbDiagnosticModel
    diagnosticCount As Long
    suppressWarningConsole As Long
End Type

' Streaming source item payload. Declaration tokens are retained in the common
' table for shared indexing; full function bodies stay transient.
Private Type C2fbSourceItemModel
    declaration As C2fbDeclarationModel
    body As String
End Type

Private Type C2fbReplacementRuleModel
    sourceKey As String
    sourceText As String
    replacementText As String
    toFreeBasic As Long
End Type

Private Type CGenericHeaderTypeAlias
    sourceName As String
    freeBasicName As String
    baseType As String
    characterKind As Long
    arrayElementType As String
    arrayCount As Long
    arrayBounds As String
    emitted As Long
    isTag As Long
    isArray As Long
    isFunction As Long
    isForward As Long
    deferredAfterRecords As Long
    functionPointerDepth As Long
    alignmentValue As Long
    naturalAlignmentValue As Long
End Type

Private Type CGenericTypeOverride
    sourceName As String
    freeBasicType As String
    isTypedefHint As Long
    alignmentValue As Long
End Type

Private Type CGenericTypedefExpansion
    sourceName As String
    matched As Long
End Type

Private Type CGenericMacroExpansionPattern
    pattern As String
    matched As Long
    expandedCount As Long
    unsupportedCount As Long
    excludedCount As Long
    automatic As Long
End Type

Private Type CGenericForwardDeclarationPattern
    pattern As String
    matched As Long
End Type

Enum C2fbSymbolRenameNamespace
    C2FB_SYMBOL_RENAME_GENERAL = 0
    C2FB_SYMBOL_RENAME_TYPEDEF = 1
    C2FB_SYMBOL_RENAME_TAG = 2
    C2FB_SYMBOL_RENAME_PROCEDURE = 3
    C2FB_SYMBOL_RENAME_DEFINE = 4
    C2FB_SYMBOL_RENAME_MACRO_PARAMETER = 5
    C2FB_SYMBOL_RENAME_STATIC_OBJECT_REUSE = 6
End Enum

Enum C2fbGenericSymbolExcludeKind
    C2FB_GENERIC_SYMBOL_EXCLUDE_ANY = 0
    C2FB_GENERIC_SYMBOL_EXCLUDE_PROCEDURE = 1
    C2FB_GENERIC_SYMBOL_EXCLUDE_VARIABLE = 2
    C2FB_GENERIC_SYMBOL_EXCLUDE_DEFINE = 3
End Enum

Private Type CGenericSymbolRename
    sourceName As String
    freeBasicName As String
    renameNamespace As C2fbSymbolRenameNamespace
    reusedStaticFreeBasicType As String
    reusedStaticArrayCount As Long
    matched As Long
End Type

Private Type CGenericStringOverride
    sourceName As String
    mode As Long
End Type

Private Type CGenericArraySizeOverride
    sourceName As String
    arrayCount As Long
    applied As Long
End Type

Private Type CGenericSymbolExclude
    sourceName As String
    excludeKind As C2fbGenericSymbolExcludeKind
End Type

Private Type CGenericReservedMacroExport
    pattern As String
    matched As Long
End Type

Private Type CGenericSourcePattern
    pattern As String
    matched As Long
    automatic As Long
End Type

Private Type CGenericSourceRoute
    pattern As String
    destination As String
End Type

Private Type CGenericPreservedIncludeMap
    cHeaderPattern As String
    freeBasicInclude As String
    matched As Long
End Type

Private Type CGenericIncludeRemoval
    cHeaderName As String
    matched As Long
End Type

Private Type CGenericMoveAbove
    movingName As String
    referenceName As String
    matched As Long
    applied As Long
    hoisted As Long
    failureReason As String
End Type

Private Type CGenericDeclarationGuardPattern
    pattern As String
    matched As Long
End Type

Private Type CGenericMacroTokenConversion
    pattern As String
    matched As Long
End Type

Private Type CGenericIntegerMacroAssumption
    pattern As String
    matched As Long
End Type

Private Type CGenericDynamicMacroDivision
    pattern As String
    matched As Long
End Type

Private Type CGenericInlineMacroForce
    sourceName As String
    matched As Long
End Type

Private Type CGenericInlineBodyDrop
    sourceName As String
    matched As Long
End Type

' Symbol kind values are shared by generic declarations and body indexing.
Enum C2fbSymbolKind
    GENERIC_SYMBOL_UNSPECIFIED = 0
    GENERIC_SYMBOL_FUNCTION = 1
    GENERIC_SYMBOL_SUB = 2
    GENERIC_SYMBOL_OBJECT = 3
End Enum

Private Type C2fbGenericHeaderSymbolBindingModel
    freeBasicType As String
    returnType As String
    parameterList As String
    callingConvention As String
    arrayCount As Long
    unsizedArray As Long
    isRegistered As Long
End Type

Private Type C2fbBodyExternalObjectModel
    sourceName As String
    cName As String
    freeBasicName As String
    storageName As String
    freeBasicType As String
    initializerText As String
    pointerCount As Long
    volatileMask As Long
    arrayCount As Long
    arrayRank As Long
    arrayDimensions As String
    isArray As Long
    isUnsizedArray As Long
    isConst As Long
    isStatic As Long
    isDefinition As Long
    isReused As Long
    isAmbiguous As Long
End Type

Private Type C2fbPointerToArrayParameterModel
    procedureName As String
    parameterIndex As Long
    parameterName As String
    arrayElementType As String
    arrayElementCount As Long
    isConst As Long
    isAmbiguous As Long
End Type

Private Type C2fbBodySymbolModel
    callNameOverride As String
    linkName As String
    callingConvention As String
    returnType As String
    parameterTypes As String
    parameterCount As Long
    isVariadic As Long
    isNoReturn As Long
    isStatic As Long
    isExternal As Long
    isAmbiguous As Long
    hasDefinition As Long
    needsDefinition As Long
    isRuntime As Long
    isDeclared As Long
End Type

' Identity and ambiguity are shared. Each adapter keeps its own binding facts
' in a separate submodel so body signatures cannot overwrite header bindings.
Private Type C2fbSymbolModel
    sourceName As String
    cName As String
    freeBasicName As String
    kind As C2fbSymbolKind
    ambiguous As Long
    genericHeader As C2fbGenericHeaderSymbolBindingModel
    body As C2fbBodySymbolModel
End Type

Private Type GenericRecordField
    itemKind As C2fbRecordBindingItemKind
    isUnion As Long
    packValue As Long
    isBitField As Long
    isArraySizeHinted As Long
    bitWidth As Long
    bitStorageWidth As Long
    isZeroLengthArray As Long
    name As String
    sourceName As String
    fieldType As String
    alignmentStorageType As String
    arrayCount As Long
    arrayBounds As String
    zeroArrayAccessorName As String
    zeroArrayStorageName As String
    zeroArrayPreviousFieldName As String
    zeroArrayPreviousArrayCount As Long
End Type

Private Type GenericEnumMember
    sourceName As String
    freeBasicName As String
    enumTypeName As String
    enumTagName As String
    integerValue As Long
    integerValueKnown As Long
    enumValueRetryStage As Long
    isEmitted As Long
End Type

Private Type C2fbMacroOrigin
    sourceName As String
    sourceKey As String
    sourceLocation As C2fbSourceLocationModel
End Type

Private Type CBodyTypeAlias
    name As String
    baseType As String
    arrayElementType As String
    arrayCount As Long
    callbackType As String
    pointerCount As Long
    isConst As Long
    isArray As Long
    ambiguous As Long
End Type

Private Type CBodyRecordField
    ownerName As String
    name As String
    freeBasicName As String
    sourceType As String
    pointerCount As Long
    isConst As Long
    volatileMask As Long
    isArray As Long
    isFlexibleArray As Long
    arrayBound As String
    freeBasicArrayCountExpression As String
    bitWidth As Long
    bitOffset As Long
    nestedRecordKind As C2fbRecordKind
    callbackType As String
    anonymousUnionGroup As Long
End Type

Private Type CBodyRecordBinding
    sourceName As String
    fbName As String
    recordKind As C2fbRecordKind
    isGenerated As Long
    staticInitializerBinding As C2fbRecordBindingModel
End Type

Private Type CBodyCallback
    fbType As String
    declaration As String
    returnType As String
    parameterTypes As String
    parameterCount As Long
    isVariadic As Long
End Type

Private Type FbBodyCallSignature
    name As String
    fbName As String
    returnType As String
    parameterTypes As String
    parameterCount As Long
    isVariadic As Long
    declaration As String
    canDeclare As Long
    isPrivate As Long
    isFallback As Long
End Type

Private Type FbBodyField
    ownerName As String
    name As String
    typeName As String
    isArray As Long
    arrayCount As Long
    freeBasicArrayCountExpression As String
    isUnionMember As Long
    isPrivate As Long
    headerName As String
End Type

Private Type FbBodyTypeAlias
    aliasName As String
    targetName As String
    isPrivate As Long
End Type

Private Type C2fbStringIndexMapModel
    keys(Any) As String
    values(Any) As Long
    itemCount As Long
    capacity As Long
End Type

' Body-only aliases, layouts, and callbacks live under one translation state.
Private Type C2fbBodyTranslationStateModel
    assumeSingleThreadedAtomics As Long
    atomicMutexRuntime As Long
    assumeZeroStaticAggregates As Long
    includeGlobalDefinitions As Long
    aliases(Any) As CBodyTypeAlias
    aliasCount As Long
    externalObjects(Any) As C2fbBodyExternalObjectModel
    externalObjectCount As Long
    pointerToArrayParameters(Any) As C2fbPointerToArrayParameterModel
    pointerToArrayParameterCount As Long
    generatedStaticDeclarations As String
    generatedStaticStorageSerial As Long
    generatedAggregateInitializerSerial As Long
    recordFields(Any) As CBodyRecordField
    recordFieldCount As Long
    recordFieldIndex As C2fbStringIndexMapModel
    recordFreeBasicNameIndex As C2fbStringIndexMapModel
    recordBindings(Any) As CBodyRecordBinding
    recordBindingCount As Long
    localRecordSerial As Long
    staticRecordSerial As Long
    anonymousUnionSerial As Long
    callbacks(Any) As CBodyCallback
    callbackCount As Long
End Type

' Generic header aliases and layouts are target-side results keyed by source
' declaration. The shared scanner keeps those decisions out of its source model.
Private Type C2fbGenericRecordPlanModel
    sourceDeclarationIndex As Long
    freeBasicName As String
    aliasFreeBasicName As String
    implementationName As String
    ifndefGuardName As String
    undefBeforeName As String
    isPrepared As Long
    isSupported As Long
    isExcluded As Long
    isOpaqueEmpty As Long
    hasNonByteFlexibleTail As Long
    bindingReady As Long
    unsupportedFieldName As String
    binding As C2fbRecordBindingModel
    useSiteTypeAliases(Any) As String
    useSiteTypeAliasCount As Long
    nestedBindings(Any) As C2fbRecordBindingModel
    nestedBindingCount As Long
    nestedBindingSequence As Long
End Type

' Helpers preserve C integer-cast semantics for untyped macro arguments.
Private Type C2fbGenericHeaderIntegerCastHelperModel
    targetType As String
    functionName As String
    guardName As String
End Type

' Private overload sets preserve operand-dependent C arithmetic in macros.
Private Type C2fbGenericHeaderOperatorHelperModel
    operatorText As String
    functionName As String
    guardName As String
End Type

' Caller policy is shared by generic-header and generic-body lowering.
Private Type C2fbGenericCPolicyModel
    replacementRules(Any) As C2fbReplacementRuleModel
    replacementRuleCount As Long
    typeOverrides(Any) As CGenericTypeOverride
    typeOverrideCount As Long
    typedefExpansions(Any) As CGenericTypedefExpansion
    typedefExpansionCount As Long
    macroExpansionPatterns(Any) As CGenericMacroExpansionPattern
    macroExpansionPatternCount As Long
    macroInDefineExpansionPatterns(Any) As CGenericMacroExpansionPattern
    macroInDefineExpansionPatternCount As Long
    macroNoExpansionPatterns(Any) As CGenericMacroExpansionPattern
    macroNoExpansionPatternCount As Long
    forwardDeclarationPatterns(Any) As CGenericForwardDeclarationPattern
    forwardDeclarationPatternCount As Long
    symbolRenames(Any) As CGenericSymbolRename
    symbolRenameCount As Long
    stringOverrides(Any) As CGenericStringOverride
    stringOverrideCount As Long
    arraySizeOverrides(Any) As CGenericArraySizeOverride
    arraySizeOverrideCount As Long
    freeBasicIncludes(Any) As String
    freeBasicIncludeCount As Long
    preservedIncludes(Any) As CGenericPreservedIncludeMap
    preservedIncludeCount As Long
    includeRemovals(Any) As CGenericIncludeRemoval
    includeRemovalCount As Long
    freeBasicLibraries(Any) As String
    freeBasicLibraryCount As Long
    freeBasicUndefines(Any) As String
    freeBasicUndefineCount As Long
    symbolExcludes(Any) As CGenericSymbolExclude
    symbolExcludeCount As Long
    includeStaticObjects As Long
    privateStaticObjects As Long
    fixUnsizedArrays As Long
    fbfrogStringDefaults As Long
    fbfrogWStringSize As Long
    preserveTypeDependencies As Long
    reservedMacroExports(Any) As CGenericReservedMacroExport
    reservedMacroExportCount As Long
    removeFirstPatterns(Any) As CGenericSymbolExclude
    removeFirstPatternCount As Long
    removeRepeatedPatterns(Any) As CGenericSymbolExclude
    removeRepeatedPatternCount As Long
    typeExcludes(Any) As CGenericSymbolExclude
    typeExcludeCount As Long
    sourceIncludes(Any) As CGenericSourcePattern
    sourceIncludeCount As Long
    sourceExcludes(Any) As CGenericSourcePattern
    sourceExcludeCount As Long
    sourceRoutes(Any) As CGenericSourceRoute
    sourceRouteCount As Long
    sourceDestination As String
    moveAboveMappings(Any) As CGenericMoveAbove
    moveAboveCount As Long
    ifndefDeclarationPatterns(Any) As CGenericDeclarationGuardPattern
    ifndefDeclarationPatternCount As Long
    undefBeforeDeclarationPatterns(Any) As CGenericDeclarationGuardPattern
    undefBeforeDeclarationPatternCount As Long
    macroTokenConversions(Any) As CGenericMacroTokenConversion
    macroTokenConversionCount As Long
    integerMacroAssumptions(Any) As CGenericIntegerMacroAssumption
    integerMacroAssumptionCount As Long
    dynamicMacroDivisions(Any) As CGenericDynamicMacroDivision
    dynamicMacroDivisionCount As Long
    inlineMacroForces(Any) As CGenericInlineMacroForce
    inlineMacroForceCount As Long
    inlineBodyDrops(Any) As CGenericInlineBodyDrop
    inlineBodyDropCount As Long
    suppressInlineFunctionBodies As Long
    generatedNamePrefix As String
    procedureNamePrefix As String
    procedureNamePrefixMatched As Long
    removeEmptyReservedDefines As Long
    dropMacroBodyScopes As Long
    windowsMsCallingConvention As Long
    cLong32 As Long
End Type

' Collection and lowering state owned by the generic-header pipeline.
Private Type C2fbGenericHeaderTranslationStateModel
    rootSourcePath As String
    usesCLongDouble As Long
    headerTypeAliases(Any) As CGenericHeaderTypeAlias
    headerTypeAliasCount As Long
    title As String
    licenseText As String
    translatorsText As String
    verbosityLevel As Long
    cppMode As Long
    traditionalPreprocessorFallback As Long
    traditionalPreprocessorFallbackEnabled As Long
    preserveMissingIncludes As Long
    typeAliasIndex As C2fbStringIndexMapModel
    freeBasicTypeAliasIndex As C2fbStringIndexMapModel
    functionOccurrenceIndex As C2fbStringIndexMapModel
    functionPrototypeIndex As C2fbStringIndexMapModel
    typeNameIndex As C2fbStringIndexMapModel
    typeNameIndexedCount As Long
    outputNameIndex As C2fbStringIndexMapModel
    outputNameIndexedCount As Long
    sourceNameIndex As C2fbStringIndexMapModel
    sourceNameIndexedCount As Long
    requiredTypeDependencies(Any) As String
    requiredTypeDependencyCount As Long
    recordPlans(Any) As C2fbGenericRecordPlanModel
    recordPlanCount As Long
    enumMembers(Any) As GenericEnumMember
    enumMemberCount As Long
    ' Exact-name lookup preserves the first source enumerator on duplicates.
    enumMemberIndex As C2fbStringIndexMapModel
    headerMacros(Any) As C2fbGenericHeaderMacroModel
    headerMacroCount As Long
    headerMacroIndex As C2fbStringIndexMapModel
    integerCastHelpers(Any) As C2fbGenericHeaderIntegerCastHelperModel
    integerCastHelperCount As Long
    operatorHelpers(Any) As C2fbGenericHeaderOperatorHelperModel
    operatorHelperCount As Long
    macroOrigins(Any) As C2fbMacroOrigin
    macroOriginCount As Long
    macroOriginIndex As C2fbStringIndexMapModel
    macroOccurrences(Any) As C2fbMacroDefinitionModel
    macroOccurrenceCount As Long
End Type

Private Type C2fbGenericCTranslationStateModel
    policy As C2fbGenericCPolicyModel
    header As C2fbGenericHeaderTranslationStateModel
End Type

Private Type C2fbTranslationTargetStateModel
    profile As C2fbTargetProfile
    sourceMapMode As C2fbSourceMapMode
End Type

Private Type C2fbSymbolTableStateModel
    symbols(Any) As C2fbSymbolModel
    symbolCount As Long
    nameIndex As C2fbStringIndexMapModel
End Type

Private Type C2fbLibraryPragmaModel
    libraryName As String
    sourceLocation As C2fbSourceLocationModel
End Type

' Source declarations and scanner locations remain available without target mapping.
Private Type C2fbSourceUnitStateModel
    diagnosticState As C2fbDiagnosticStateModel
    declarations(Any) As C2fbDeclarationModel
    declarationCount As Long
    cppMode As Long
    libraryPragmas(Any) As C2fbLibraryPragmaModel
    libraryPragmaCount As Long
End Type

Private Type C2fbTranslationContext
    ' Invalid until the owning adapter configures the active target state.
    target As C2fbTranslationTargetStateModel
    sourceUnit As C2fbSourceUnitStateModel
    symbolTable As C2fbSymbolTableStateModel

    ' Keep mode-owned state separate from shared declaration and symbol facts.
    body As C2fbBodyTranslationStateModel
    genericC As C2fbGenericCTranslationStateModel
End Type

Private Type C2fbNameSetModel
    slots(Any) As String
    itemCount As Long
    capacity As Long
End Type

Private Type C2fbProjectCatalog
    sourceDirectory As String
    sourceRecursive As Long
    ready As Long
    callableNames(Any) As String
    callableNameCount As Long
    callableNameSet As C2fbNameSetModel
    localDeclarationNames(Any) As String
    localDeclarationNameCount As Long
    localDeclarationNameSet As C2fbNameSetModel
    existingProcedureNames(Any) As String
    existingProcedureNameCount As Long
    existingProcedureNameSet As C2fbNameSetModel
    bodyCallSignatures(Any) As FbBodyCallSignature
    bodyCallSignatureCount As Long
    bodyCallSignatureMap As C2fbStringIndexMapModel
    bodyFields(Any) As FbBodyField
    bodyFieldCount As Long
    ' Fast exact-name lookup before following conflicting Type aliases.
    bodyRecordOwnerMap As C2fbStringIndexMapModel
    ' Public owners let C-to-FreeBASIC type matching avoid scanning every field.
    bodyPublicRecordOwnerMap As C2fbStringIndexMapModel
    bodyPublicRecordOwnerExactMap As C2fbStringIndexMapModel
    bodyFieldIndex As C2fbStringIndexMapModel
    bodyTypeAliases(Any) As FbBodyTypeAlias
    bodyTypeAliasCount As Long
    bodyTypeAliasMap As C2fbStringIndexMapModel
End Type

/' end of c2fb_model.bi '/
