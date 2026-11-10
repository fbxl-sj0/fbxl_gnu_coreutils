/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_contracts.bi

    Purpose:

        Declare the internal services shared across C2FB pipeline modules.

    Responsibilities:

        - Describe cross-module declaration, type, symbol, and body services.
        - Keep include-order dependencies out of the command-line driver.
        - Define the narrow C runtime call used by the process adapter.

    This file intentionally does NOT contain:

        - Service implementations or translation policy.
        - Command parsing, dispatch, or output formatting.
'/

' -------------------------------------------------------------------------
' Source declarations and shared C syntax
' -------------------------------------------------------------------------

Declare Sub ReportError(ByVal message As String)
Declare Function CollectC2fbDeclarationsInSourceUnit( _
    ByRef sourceUnit As C2fbSourceUnitStateModel, _
    ByRef request As C2fbDeclarationScanRequestModel _
) As Long
Declare Function TranslateGenericHeaderStringMacro( _
    ByVal sourceText As String, ByRef outputValue As String _
) As Long
Declare Function DecodeCCharacterConstant( _
    ByVal sourceText As String, ByRef position As Long, _
    ByRef characterValue As Long _
) As Long
Declare Function SkipCDeclaratorGroup( _
    tokens() As String, ByRef position As Long, ByVal lastToken As Long, _
    ByVal openingToken As String, ByVal closingToken As String _
) As Long
Declare Function ParseCFunctionDeclarationModel( _
    tokens() As String, ByVal tokenCount As Long, _
    ByRef declaration As C2fbFunctionDeclarationModel, _
    ByVal allowDefaultArguments As Long = 0 _
) As Long
Declare Function IsCFunctionReturnTypePrefix( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long _
) As Long
Declare Function ParseCDeclaratorModel( _
    tokens() As String, ByRef position As Long, ByVal lastToken As Long, _
    ByRef declarator As C2fbDeclaratorModel, ByVal depth As Long = 0, _
    ByVal allowAbstract As Long = 0 _
) As Long
Declare Function SplitC2fbTokenList( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ranges() As C2fbTokenRangeModel, ByRef rangeCount As Long _
) As Long
Declare Function FindC2fbTopLevelAssignmentToken( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef assignmentToken As Long _
) As Long
Declare Function BuildC2fbDeclaratorPartTokens( _
    sourceTokens() As String, sourceRanges() As C2fbTokenRangeModel, _
    ByVal sourceRangeCount As Long, ByVal partIndex As Long, _
    ByVal commonTypeTokenCount As Long, itemTokens() As String, _
    ByRef itemTokenCount As Long _
) As Long
Declare Function GenericLastIdentifierPosition( _
    ByVal sourceText As String, ByVal identifier As String _
) As Long
Declare Function ParseGenericArrayBoundsInDeclaration( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByVal firstBracketPosition As Long, _
    ByVal expectedDimensionCount As Long, ByRef arrayBounds As String, _
    ByRef firstDimensionCount As Long, ByRef totalElementCount As Long, _
    ByRef isUnsized As Long, ByVal allowUnsized As Long = 0, _
    ByVal allowZeroLength As Long = 0, _
    ByVal unsizedBoundHint As Long = 0 _
) As Long
Declare Function CombineGenericArrayBounds( _
    ByVal firstBounds As String, ByVal secondBounds As String _
) As String
Declare Sub ApplyGenericMoveAboveToDeclarationParts( _
    ByRef translation As C2fbTranslationContext, _
    parts() As String, ByVal partCount As Long, ByVal commonType As String, _
    partOrder() As Long _
)
' -------------------------------------------------------------------------
' Generic C mapping and shared symbol catalog
' -------------------------------------------------------------------------

Declare Function GenericIdentifierMatchesPattern( _
    ByVal sourceName As String, ByVal pattern As String _
) As Long
Declare Function TranslateGenericHeaderIntegerExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String, _
    ByVal depth As Long, ByVal integerDivisionAssumed As Long = 0, _
    ByVal dynamicIntegerDivision As Long = 0 _
) As Long
Declare Function TranslateGenericHeaderMacroExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal rawValue As String, ByRef freeBasicExpression As String, _
    ByVal integerDivisionAssumed As Long = 0 _
) As Long
Declare Function RewriteGenericMacroCharacterConstants( _
    ByVal sourceExpression As String, ByRef normalizedExpression As String _
) As Long
Declare Function GenericStringElementTypeInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal freeBasicType As String, ByRef qualifier As String _
) As String
Declare Function ApplyGenericStringOverrideModeInHeader( _
    ByRef headerState As C2fbGenericHeaderTranslationStateModel, _
    ByVal overrideMode As Long, ByVal freeBasicType As String _
) As String
Declare Function GenericHeaderPreprocessorSizeValue( _
    ByRef translation As C2fbTranslationContext, ByVal macroName As String _
) As Long
Declare Function ParseCTypeModel( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef parsedType As C2fbCTypeModel _
) As Long
Declare Sub ResetC2fbSymbolTableInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal initialCapacity As Long _
)
Declare Function EnsureC2fbSymbolInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByVal cName As String, _
    ByVal freeBasicName As String, ByVal kind As C2fbSymbolKind _
) As Long
Declare Function LookupCBodyTypeAliasInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal typeName As String, _
    ByRef pointerCount As Long, _
    ByRef isConst As Long _
) As String
Declare Function LookupCBodyRecordBindingInContext( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As String
Declare Function LookupCBodyGeneratedRecordBindingInContext( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As String
Declare Function FbBodyCallSignatureIndex( _
    ByRef catalog As C2fbProjectCatalog, ByVal procedureName As String _
) As Long
Declare Function FbBodyCallSignatureAliasIndex( _
    ByRef catalog As C2fbProjectCatalog, ByVal cName As String _
) As Long

' -------------------------------------------------------------------------
' Body type, callback, layout, and output services
' -------------------------------------------------------------------------

Declare Sub ResolveCBodyCallbackTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, tokens() As String, _
    ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef result As C2fbCallbackTypeResultModel, ByVal depth As Long, _
    ByVal typeMappingKind As C2fbTypeMappingKind, _
    ByVal allowPointerLayers As Long = 0, _
    ByVal allowFunctionParameterDecay As Long = 0 _
)
Declare Function IsCBodyCallbackTypeInContext( _
    ByRef translation As C2fbTranslationContext, ByVal fbType As String _
) As Long
Declare Sub ResetCBodyCallbackTypesInContext( _
    ByRef translation As C2fbTranslationContext _
)
Declare Function CBodyCallbackDeclarationInContext( _
    ByRef translation As C2fbTranslationContext, ByVal fbType As String _
) As String
Declare Function CBodyCallbackTypesCompatibleInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal leftType As String, ByVal rightType As String, _
    ByVal depth As Long _
) As Long
Declare Function CBodyStdCallTokenCount( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long _
) As Long
Declare Function NestedCBodyCallbackCallConv( _
    tokens() As String, ByVal firstToken As Long, _
    ByVal parameterOpen As Long _
) As String
Declare Function BuildCBodyCallbackReturnChainInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, tokens() As String, _
    ByVal firstToken As Long, ByVal lastToken As Long, _
    ByVal functionOpenPositions As String, ByVal returnType As String, _
    ByVal depth As Long, ByVal typeMappingKind As C2fbTypeMappingKind, _
    ByRef outerCallbackType As String, ByRef fullDeclaration As String _
) As Long
Declare Function MappedFbBodyRecord( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As String
Declare Function MappedFbBodyTypeAlias( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As String
Declare Function IsMappedFbBodyProcedureTypeAlias( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As Long
Declare Function CBodyRecordName( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal fbType As String _
) As String
Private Declare Function RegisterCBodyAnonymousRecord( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal recordBody As String, _
    ByRef generatedRecordName As String, _
    ByVal recordKind As C2fbRecordKind = C2FB_RECORD_STRUCT, _
    ByVal generatedNamePrefix As String = "c2fb_local_record_", _
    ByVal useStaticRecordSerial As Long = 0, _
    ByVal sourceRecordTag As String = "" _
) As Long
Declare Function CBodyRecordSizeIsKnown( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As Long
Private Declare Function GenericHeaderSimpleRecordSizeInBytes( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicType As String _
) As Long
Declare Function CBodyMappedRecordLayoutMatchesActiveC( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceName As String _
) As Long
Declare Function SimplePointeeType(ByVal typeName As String) As String
Declare Function CBodyUsesProcedure( _
    ByVal bodyText As String, ByVal procedureName As String _
) As Long
Declare Function NormalizeFbBodyType( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As String
Private Declare Function SimpleIntegerWidthInBits( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As Long
Private Declare Function SimpleArithmeticTypeIsUnsigned( _
    ByRef catalog As C2fbProjectCatalog, ByVal typeName As String _
) As Long
Declare Function FbProcedureName(ByVal sourceLine As String) As String
Declare Function FbProcedureAliasName(ByVal sourceLine As String) As String
Declare Function FbDeclarationAliasName(ByVal sourceLine As String) As String
Declare Function NeedsFbBodyHeader( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, ByVal headerName As String, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long, _
    ByRef headerProviderCache As C2fbStringIndexMapModel _
) As Long
Declare Function TranslateSimpleExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal inputExpression As String, _
    ByRef outputExpression As String, _
    ByRef hasBooleanOperator As Long, _
    ByRef hasFunctionCall As Long, _
    callableNames() As String, _
    ByVal callableCount As Long, _
    parameterNames() As String, _
    parameterAliases() As String, _
    parameterTypes() As String, _
    ByVal parameterCount As Long, _
    ByVal targetType As String = "", _
    ByVal allowBodyReplacements As Long = -1, _
    ByVal requireConstant As Long = 0, _
    ByVal targetIsBoolean As Long = 0 _
) As Long

' -------------------------------------------------------------------------
' Process boundary
' -------------------------------------------------------------------------

Extern "C"
    Declare Function c2fbSystem CDecl Alias "system" ( _
        ByVal commandText As Const ZString Ptr _
    ) As Long
End Extern

/' end of c2fb_contracts.bi '/
