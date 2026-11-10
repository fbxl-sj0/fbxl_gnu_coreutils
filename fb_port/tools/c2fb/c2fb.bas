/'
    Project: SQLite FreeBASIC port tools

    File: c2fb.bas

    Purpose:

        Assemble the C2FB command driver and shared translation core.

    Responsibilities:

        - Assemble the shared pipeline modules and their internal contracts.
        - Initialize command-local translation and project contexts.
        - Dispatch typed command requests to their conversion adapters.
        - Preserve the command-line entry point for all supported modes.

    This file intentionally does NOT contain:

        - Shared service declarations or translation implementations.
        - Mode-specific SQLite table, define, and header adapter policy.
        - Generic C override policy, diagnostic collection, or output formatting.
'/

#lang "fb"

#include once "c2fb_model.bi"
#include once "c2fb_contracts.bi"
#include once "c2fb_context.bi"
#include once "c2fb_output.bi"
#include once "c2fb_csv_output.bi"
#include once "c2fb_file_input.bi"
#include once "c2fb_api_routines.bi"
#include once "c2fb_names.bi"
#include once "c2fb_source_files.bi"
#include once "c2fb_arguments.bi"
#include once "c2fb_c_syntax.bi"
#include once "c2fb_generic_pragmas.bi"
#include once "c2fb_source_lines.bi"
#include once "c2fb_directives.bi"
#include once "c2fb_lexer.bi"
#include once "c2fb_macro_syntax.bi"
#include once "c2fb_declaration_helpers.bi"
#include once "c2fb_inputs.bi"

#include once "c2fb_body_state.bi"
#include once "c2fb_diagnostics.bi"
#include once "c2fb_api_routines_adapter.bi"
#include once "c2fb_process.bi"

#include once "c2fb_source_map.bi"

Private Function FileNameOnly(ByVal path As String) As String
    Return C2fbOutputFileNameOnly(path)
End Function

#include once "c2fb_replacements.bi"

#include once "c2fb_generic_policy.bi"
#include once "c2fb_generic_header_state.bi"
#include once "c2fb_types.bi"
#include once "c2fb_sqlite_type_policy.bi"
#include once "c2fb_windows_types.bi"
#include once "c2fb_type_resolution.bi"

#include once "c2fb_parameters.bi"

#include once "c2fb_prototypes.bi"

#include once "c2fb_generic_macro_collection.bi"
#include once "c2fb_generic_include_preservation.bi"
#include once "c2fb_generic_enums.bi"
#include once "c2fb_generic_sizeof.bi"

#include once "c2fb_sqlite_fp_tables.bi"

#include once "c2fb_integer_expr.bi"

#include once "c2fb_generic_macro_lowering.bi"
#include once "c2fb_generic_macro_output.bi"
#include once "c2fb_generic_macro_expansion.bi"

#include once "c2fb_sqlite_defines.bi"

#include once "c2fb_generic_records.bi"
#include once "c2fb_generic_declarations.bi"
#include once "c2fb_generic_occurrences.bi"
#include once "c2fb_declarations.bi"
#include once "c2fb_function_scanner.bi"
#include once "c2fb_generic_forward_declarations.bi"
#include once "c2fb_generic_typedefs.bi"
#include once "c2fb_generic_ordering.bi"
#include once "c2fb_generic_header_pipeline.bi"
#include once "c2fb_generic_header_adapter.bi"

#include once "c2fb_sqlite_header.bi"

#include once "c2fb_function_index.bi"


#include once "c2fb_callbacks.bi"
#include once "c2fb_symbols.bi"
#include once "c2fb_layouts.bi"
#include once "c2fb_body_call_signatures.bi"
#include once "c2fb_c_records.bi"
#include once "c2fb_expr.bi"
#include once "c2fb_project_catalog.bi"
#include once "c2fb_body_declarations.bi"
#include once "c2fb_body_statements.bi"
#include once "c2fb_generic_inline_functions.bi"
#include once "c2fb_body_switch.bi"

#include once "c2fb_body_lowering.bi"

#include once "c2fb_body_output.bi"

#include once "c2fb_body_pipeline.bi"

#include once "c2fb_simple_body_adapter.bi"

#include once "c2fb_generic_body_adapter.bi"

#include once "c2fb_sqlite_preprocessed_adapter.bi"

Private Sub RunC2fbCommandLine(ByVal argumentCount As Long)
    Dim c2fbTranslation As C2fbTranslationContext
    Dim c2fbProjectCatalog As C2fbProjectCatalog
    Dim commandRequest As C2fbCommandModel
    Dim commandUsage As String
    Dim commandError As String
    If ReadC2fbCommandModel( _
        argumentCount, commandRequest, commandUsage, commandError) = 0 Then
        If commandError <> "" Then ReportError(commandError)
        Print commandUsage
        End 2
    End If

    Select Case commandRequest.kind
    Case C2FB_COMMAND_DEFINES
        InitializeC2fbTranslationSession(c2fbTranslation)
        ConvertDefines(c2fbTranslation, commandRequest.fileRequest)
    Case C2FB_COMMAND_SIMPLE_BODY
        InitializeC2fbTranslationSession(c2fbTranslation)
        TranslateCBodyRequest( _
            c2fbTranslation, c2fbProjectCatalog, commandRequest.bodyRequest)
    Case C2FB_COMMAND_GENERIC_BODY
        InitializeC2fbTranslationSession(c2fbTranslation)
        TranslateGenericBodyRequest( _
            c2fbTranslation, c2fbProjectCatalog, commandRequest.genericBodyRequest)
    Case C2FB_COMMAND_PREPROCESSED_BODY
        InitializeC2fbTranslationSession(c2fbTranslation)
        ConvertPreprocessedBodyRequest( _
            c2fbTranslation, c2fbProjectCatalog, _
            commandRequest.preprocessedBodyRequest)
    Case C2FB_COMMAND_FP_TABLES
        ConvertFpTables(commandRequest.fileRequest)
    Case C2FB_COMMAND_FUNCTION_INDEX
        ConvertFunctionTree(commandRequest.functionIndexRequest)
    Case C2FB_COMMAND_FUNCTION_RECONCILE
        ReconcileFunctionTree(commandRequest.functionReconcileRequest)
    Case C2FB_COMMAND_API_ROUTINES
        ConvertC2fbApiRoutinesRequest(commandRequest.apiRoutinesRequest)
    Case C2FB_COMMAND_GENERIC_HEADER
        InitializeC2fbTranslationSession(c2fbTranslation)
        TranslateGenericHeader( _
            c2fbTranslation, c2fbProjectCatalog, _
            commandRequest.genericHeaderRequest)
    Case C2FB_COMMAND_HEADER
        InitializeC2fbTranslationSession(c2fbTranslation)
        ConvertHeader( _
            c2fbTranslation, c2fbProjectCatalog, commandRequest.fileRequest)
    Case Else
        ReportError("invalid internal C2FB command kind")
    End Select

End Sub

RunC2fbCommandLine(__FB_ARGC__)

/' end of c2fb.bas '/
