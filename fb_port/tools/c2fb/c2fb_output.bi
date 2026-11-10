/'
    Project: C2FB

    File: c2fb_output.bi

    Purpose:

        Format shared FreeBASIC binding models across C2FB tools.

    Responsibilities:

        - Consume procedure and record models independently of C input syntax.
        - Write through the shared generated-file output model, not raw handles.
        - Store external object bindings independently of C input syntax.
        - Store FreeBASIC type aliases independently of their source.
        - Store scalar constants independently of their source.
        - Store initialized integer arrays independently of their source scan.
        - Store object-like and function-like macro bindings independently of their source.
        - Dispatch lowered bindings and diagnostics through one output item model.
        - Format opt-in verbosity messages through a shared console writer.
        - Apply optional undef-before and ifndef guards around complete output items.
        - Format Declare and definition heads from the same signature model.
        - Write external procedure declarations with their C Alias names.
        - Write fixed and unsized external object bindings consistently.
        - Write resolved struct and union layouts with their target pack caps.
        - Format anonymous nested Type/Union blocks from record item streams.

    This file intentionally does NOT contain:

        - C parsing, target type resolution, or symbol registration.
        - C statement translation or body candidate file formatting.
        - Generated-file lifecycle, CSV parsing, or file-specific include policy.
'/

#include once "c2fb_model.bi"

Private Type C2fbObjectBindingModel
    freeBasicName As String
    cName As String
    linkName As String
    freeBasicType As String
    arrayCount As Long
    arrayBounds As String
    isUnsizedArray As Long
    isByRef As Long
    isModuleStatic As Long
    isThreadLocal As Long
    isPrivate As Long
    isConstAggregateAccessor As Long
    storageName As String
    stringAccessorType As String
    aliasAccessorTarget As String
    initialValue As String
End Type

Private Type C2fbTypeAliasBindingModel
    freeBasicName As String
    targetType As String
    alignmentValue As Long
End Type

Private Type C2fbConstantBindingModel
    freeBasicName As String
    targetType As String
    valueExpression As String
End Type

Private Type C2fbIntegerConstantArrayBindingModel
    name As String
    elementType As String
    lowerBound As Long
    values(Any) As ULongInt
    valueCount As Long
    valueCapacity As Long
End Type

Private Type C2fbMacroBindingModel
    name As String
    parameters As String
    bodyText As String
    isFunctionLike As Long
    isBlock As Long
End Type

#include once "c2fb_generated_file_output.bi"

Private Function C2fbStringLiteral(ByVal value As String) As String
    Dim literal As String = Chr(34)
    For position As Long = 1 To Len(value)
        Dim currentByte As Long = Asc(value, position)
        literal &= Chr(currentByte)
        If currentByte = Asc(Chr(34)) Then literal &= Chr(34)
    Next
    Return literal & Chr(34)
End Function

Enum C2fbOutputItemKind
    C2FB_OUTPUT_ITEM_INVALID = 0
    C2FB_OUTPUT_ITEM_PROCEDURE = 1
    C2FB_OUTPUT_ITEM_OBJECT = 2
    C2FB_OUTPUT_ITEM_RECORD = 3
    C2FB_OUTPUT_ITEM_TYPE_ALIAS = 4
    C2FB_OUTPUT_ITEM_CONSTANT = 5
    C2FB_OUTPUT_ITEM_MACRO = 6
    C2FB_OUTPUT_ITEM_DIAGNOSTIC = 7
    C2FB_OUTPUT_ITEM_INTEGER_CONSTANT_ARRAY = 8
    C2FB_OUTPUT_ITEM_SKIPPED_DIAGNOSTIC = 9
End Enum
' Bound array initializers before allocating generated output models.
Private Const MAX_C2FB_INTEGER_ARRAY_VALUES As Long = 65536
Private Const INITIAL_C2FB_INTEGER_ARRAY_CAPACITY As Long = 16
' Keep generated integer array initializers to a readable number of values per line.
Private Const C2FB_INTEGER_ARRAY_VALUES_PER_LINE As Long = 6

' The item kind is the backend's only choice point for binding formatting.
Private Type C2fbOutputItemModel
    kind As C2fbOutputItemKind
    ifndefGuardName As String
    undefBeforeName As String
    procedureBinding As C2fbProcedureBindingModel
    objectBinding As C2fbObjectBindingModel
    recordBinding As C2fbRecordBindingModel
    typeAlias As C2fbTypeAliasBindingModel
    constantBinding As C2fbConstantBindingModel
    macroBinding As C2fbMacroBindingModel
    diagnostic As C2fbDiagnosticModel
    integerConstantArrayBinding As C2fbIntegerConstantArrayBindingModel
End Type

Private Function AppendC2fbIntegerConstantArrayValue( _
    ByRef binding As C2fbIntegerConstantArrayBindingModel, _
    ByVal value As ULongInt _
) As Long
    If binding.valueCount >= MAX_C2FB_INTEGER_ARRAY_VALUES Then Return 0
    If binding.valueCount >= binding.valueCapacity Then
        If binding.valueCapacity = 0 Then
            binding.valueCapacity = INITIAL_C2FB_INTEGER_ARRAY_CAPACITY
            If binding.valueCapacity > MAX_C2FB_INTEGER_ARRAY_VALUES Then _
                binding.valueCapacity = MAX_C2FB_INTEGER_ARRAY_VALUES
            ReDim binding.values(0 To binding.valueCapacity - 1)
        Else
            Dim nextCapacity As Long = binding.valueCapacity * 2
            If nextCapacity > MAX_C2FB_INTEGER_ARRAY_VALUES Then _
                nextCapacity = MAX_C2FB_INTEGER_ARRAY_VALUES
            ReDim Preserve binding.values(0 To nextCapacity - 1)
            binding.valueCapacity = nextCapacity
        End If
    End If
    binding.values(binding.valueCount) = value
    binding.valueCount += 1
    Return -1
End Function

Declare Sub WriteC2fbMacroBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef macroBinding As C2fbMacroBindingModel, _
    ByVal ifndefGuardName As String = "", _
    ByVal undefBeforeName As String = "" _
)
Declare Sub WriteC2fbTypeAlias( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef typeAlias As C2fbTypeAliasBindingModel, _
    ByVal ifndefGuardName As String = "", _
    ByVal undefBeforeName As String = "" _
)
Declare Sub WriteC2fbOutputItem( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef outputItem As C2fbOutputItemModel _
)

Private Function C2fbProcedureHeadText( _
    ByRef procedureBinding As C2fbProcedureBindingModel, _
    ByVal isDeclaration As Long _
) As String
    Dim prefix As String
    If isDeclaration <> 0 Then
        prefix = "Declare "
    ElseIf procedureBinding.isPrivate <> 0 Then
        prefix = "Private "
    End If
    Dim headText As String
    If procedureBinding.isSub <> 0 Then
        headText = prefix & "Sub " & procedureBinding.freeBasicName
    Else
        headText = prefix & "Function " & procedureBinding.freeBasicName
    End If
    If procedureBinding.isWindowsMS = 0 AndAlso _
       procedureBinding.callingConvention <> "" Then _
        headText &= " " & procedureBinding.callingConvention
    ' C static procedures have file-local linkage, so Basic keeps them private
    ' and gives them a compiler-mangled name instead of a C linker alias.
    If procedureBinding.isPrivate = 0 Then
        Dim linkName As String = procedureBinding.linkName
        If linkName = "" Then linkName = procedureBinding.cName
        headText &= " Alias " & C2fbStringLiteral(linkName)
    End If
    headText &= " (" & procedureBinding.parameterList & ")"
    If procedureBinding.isSub = 0 Then _
        headText &= " As " & procedureBinding.returnType
    Return headText
End Function

Private Sub FormatC2fbProcedureBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef procedureBinding As C2fbProcedureBindingModel _
)
    If procedureBinding.isWindowsMS <> 0 Then _
        WriteC2fbOutputLine(outputFile, "Extern " & Chr(34) & "Windows-MS" & Chr(34))
    WriteC2fbOutputLine(outputFile, C2fbProcedureHeadText(procedureBinding, -1))
    If procedureBinding.isWindowsMS <> 0 Then _
        WriteC2fbOutputLine(outputFile, "End Extern")
End Sub

Private Sub FormatC2fbObjectBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef objectBinding As C2fbObjectBindingModel _
)
    Dim isExternalThreadLocal As Long = CInt( _
        objectBinding.isThreadLocal <> 0 AndAlso _
        objectBinding.isModuleStatic = 0) * -1
    If objectBinding.isUnsizedArray <> 0 Then
        If objectBinding.aliasAccessorTarget <> "" Then
            Dim accessorAlias As C2fbMacroBindingModel
            accessorAlias.name = objectBinding.freeBasicName
            accessorAlias.parameters = "c2fb_index"
            accessorAlias.bodyText = objectBinding.aliasAccessorTarget & "(c2fb_index)"
            accessorAlias.isFunctionLike = -1
            WriteC2fbMacroBinding(outputFile, accessorAlias)
            Exit Sub
        End If

        ' Extern declarations need concrete storage, so expose C's first array
        ' element through a scalar alias and an indexed macro.
        If objectBinding.isModuleStatic <> 0 Then
            Dim storageDeclaration As String
            If objectBinding.isThreadLocal <> 0 AndAlso _
               objectBinding.isPrivate <> 0 Then
                storageDeclaration = "Private Thread Local Dim Shared "
            ElseIf objectBinding.isThreadLocal <> 0 Then
                storageDeclaration = "Thread Local Dim Shared "
            ElseIf objectBinding.isPrivate <> 0 Then
                storageDeclaration = "Private Dim Shared "
            Else
                storageDeclaration = "Dim Shared "
            End If
            storageDeclaration &= objectBinding.storageName & " As " & _
                objectBinding.freeBasicType
            If objectBinding.initialValue <> "" Then _
                storageDeclaration &= " = " & objectBinding.initialValue
            WriteC2fbOutputLine(outputFile, storageDeclaration)
        Else
            Dim storageLinkName As String = objectBinding.linkName
            If storageLinkName = "" Then storageLinkName = objectBinding.cName
            If isExternalThreadLocal <> 0 Then _
                WriteC2fbOutputLine(outputFile, "Extern " & Chr(34) & "C" & Chr(34))
            Dim storagePrefix As String = "Extern "
            If isExternalThreadLocal <> 0 Then _
                storagePrefix = "Thread Local Extern "
            WriteC2fbOutputLine( _
                outputFile, storagePrefix & objectBinding.storageName & " Alias " & _
                C2fbStringLiteral(storageLinkName) & " As " & _
                objectBinding.freeBasicType)
            If isExternalThreadLocal <> 0 Then _
                WriteC2fbOutputLine(outputFile, "End Extern")
        End If
        Dim objectAccessor As C2fbMacroBindingModel
        objectAccessor.name = objectBinding.freeBasicName
        If objectBinding.stringAccessorType <> "" Then
            objectAccessor.bodyText = "(*Cptr(" & objectBinding.stringAccessorType & ", @" & _
                objectBinding.storageName & "))"
        Else
            objectAccessor.parameters = "c2fb_index"
            objectAccessor.bodyText = "((@" & objectBinding.storageName & ")[c2fb_index])"
            objectAccessor.isFunctionLike = -1
        End If
        WriteC2fbMacroBinding(outputFile, objectAccessor)
        Exit Sub
    End If

    If objectBinding.isConstAggregateAccessor <> 0 Then
        ' FBC cannot declare Const UDT storage directly. Keep the storage
        ' declaration separate and expose the C name through a Const view.
        Dim storageDeclaration As String
        Dim storageType As String = objectBinding.freeBasicType
        If Left(storageType, 6) = "Const " Then _
            storageType = Trim(Mid(storageType, 7))
        If objectBinding.isModuleStatic <> 0 Then
            If objectBinding.isThreadLocal <> 0 AndAlso _
               objectBinding.isPrivate <> 0 Then
                storageDeclaration = "Private Thread Local Dim Shared "
            ElseIf objectBinding.isThreadLocal <> 0 Then
                storageDeclaration = "Thread Local Dim Shared "
            ElseIf objectBinding.isPrivate <> 0 Then
                storageDeclaration = "Private Dim Shared "
            Else
                storageDeclaration = "Dim Shared "
            End If
            storageDeclaration &= objectBinding.storageName & _
                " As " & storageType
        Else
            Dim storageLinkName As String = objectBinding.linkName
            If storageLinkName = "" Then storageLinkName = objectBinding.cName
            If isExternalThreadLocal <> 0 Then _
                WriteC2fbOutputLine(outputFile, "Extern " & Chr(34) & "C" & Chr(34))
            Dim storagePrefix As String = "Extern "
            If isExternalThreadLocal <> 0 Then _
                storagePrefix = "Thread Local Extern "
            storageDeclaration = storagePrefix & objectBinding.storageName & _
                " Alias " & C2fbStringLiteral(storageLinkName) & _
                " As " & storageType
        End If
        If objectBinding.initialValue <> "" Then _
            storageDeclaration &= " = " & objectBinding.initialValue
        WriteC2fbOutputLine(outputFile, storageDeclaration)
        If isExternalThreadLocal <> 0 Then _
            WriteC2fbOutputLine(outputFile, "End Extern")

        Dim constObjectAccessor As C2fbMacroBindingModel
        constObjectAccessor.name = objectBinding.freeBasicName
        constObjectAccessor.bodyText = "(*Cptr(" & _
            objectBinding.freeBasicType & " Ptr, @" & _
            objectBinding.storageName & "))"
        WriteC2fbMacroBinding(outputFile, constObjectAccessor)
        Exit Sub
    End If

    Dim declaration As String
    If objectBinding.isModuleStatic <> 0 AndAlso _
       objectBinding.isThreadLocal <> 0 Then
        If objectBinding.isPrivate <> 0 Then
            declaration = "Private Thread Local Dim Shared "
        Else
            declaration = "Thread Local Dim Shared "
        End If
    ElseIf objectBinding.isModuleStatic <> 0 Then
        If objectBinding.isPrivate <> 0 Then
            declaration = "Private Dim Shared "
        Else
            declaration = "Dim Shared "
        End If
    Else
        If isExternalThreadLocal <> 0 Then _
            WriteC2fbOutputLine(outputFile, "Extern " & Chr(34) & "C" & Chr(34))
        declaration = "Extern "
        If isExternalThreadLocal <> 0 Then _
            declaration = "Thread Local Extern "
    End If
    If objectBinding.isByRef <> 0 Then declaration &= "ByRef "
    declaration &= objectBinding.freeBasicName
    If objectBinding.arrayBounds <> "" Then
        declaration &= "(" & objectBinding.arrayBounds & ")"
    ElseIf objectBinding.arrayCount > 0 Then _
        declaration &= "(0 To " & Trim(Str(objectBinding.arrayCount - 1)) & ")"
    End If
    If objectBinding.isModuleStatic <> 0 Then
        declaration &= " As " & objectBinding.freeBasicType
    Else
        Dim linkName As String = objectBinding.linkName
        If linkName = "" Then linkName = objectBinding.cName
        declaration &= " Alias " & C2fbStringLiteral(linkName) & " As " & _
            objectBinding.freeBasicType
    End If
    If objectBinding.initialValue <> "" Then _
        declaration &= " = " & objectBinding.initialValue
    WriteC2fbOutputLine(outputFile, declaration)
    If isExternalThreadLocal <> 0 Then _
        WriteC2fbOutputLine(outputFile, "End Extern")
End Sub

Private Function C2fbRecordBindingHasFieldName( _
    ByRef recordBinding As C2fbRecordBindingModel, _
    ByVal candidate As String _
) As Long
    For itemIndex As Long = 0 To recordBinding.itemCount - 1
        With recordBinding.items(itemIndex)
            If .kind = C2FB_RECORD_BINDING_ITEM_FIELD AndAlso _
               LCase(.name) = LCase(candidate) Then Return -1
            If .kind = C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY AndAlso _
               (.name = candidate OrElse .zeroArrayStorageName = candidate OrElse _
                .zeroArrayAccessorName = candidate) Then Return -1
        End With
    Next
    For fieldIndex As Long = 0 To recordBinding.fieldCount - 1
        If LCase(recordBinding.fields(fieldIndex).name) = LCase(candidate) Then _
            Return -1
    Next
    Return 0
End Function

Private Function C2fbRecordBindingUnionArrayInitializerCount( _
    ByRef recordBinding As C2fbRecordBindingModel _
) As Long
    If recordBinding.isUnion = 0 OrElse recordBinding.itemCount <= 0 Then _
        Return 0

    With recordBinding.items(0)
        If .kind <> C2FB_RECORD_BINDING_ITEM_FIELD OrElse _
           .arrayCount < 1 OrElse _
           .arrayCount > MAX_C2FB_UNION_ARRAY_INITIALIZER_ELEMENTS OrElse _
           .isBitField <> 0 OrElse .alignmentStorageType <> "" OrElse _
           .fieldType = "" Then Return 0
        Return .arrayCount
    End With
End Function

Private Function C2fbRecordBindingFieldDeclarationText( _
    ByRef recordBinding As C2fbRecordBindingModel, _
    ByVal itemIndex As Long, ByVal fieldName As String, _
    ByVal fieldType As String, ByVal arrayCount As Long, _
    ByVal arrayBounds As String, ByVal alignmentStorageType As String, _
    ByVal packValue As Long, ByVal isBitField As Long, _
    ByVal bitWidth As Long, ByVal alignmentCarrierIsUnionMember As Long, _
    ByVal indentLevel As Long _
) As String
    Dim fieldIndent As String = Space(indentLevel * 4)
    Dim fieldText As String = ""
    If alignmentStorageType <> "" AndAlso _
       alignmentCarrierIsUnionMember = 0 Then
        Dim wrapperHeader As String = fieldIndent & "Union"
        Select Case packValue
        Case 1, 2, 4, 8, 16
            wrapperHeader &= " Field = " & Trim(Str(packValue))
        End Select
        fieldText = wrapperHeader
        fieldIndent = Space((indentLevel + 1) * 4)
    End If

    Dim fieldDeclaration As String = fieldIndent & fieldName
    If isBitField <> 0 Then _
        fieldDeclaration &= " : " & Trim(Str(bitWidth))
    If arrayBounds <> "" Then
        fieldDeclaration &= "(" & arrayBounds & ")"
    ElseIf arrayCount > 0 Then
        fieldDeclaration &= "(0 To " & Trim(Str(arrayCount - 1)) & ")"
    End If
    fieldDeclaration &= " As " & fieldType
    If fieldText <> "" Then fieldText &= Chr(10)
    fieldText &= fieldDeclaration

    If alignmentStorageType <> "" Then
        Dim alignmentName As String = _
            "c2fbLongDoubleAlignment_" & Trim(Str(itemIndex))
        While C2fbRecordBindingHasFieldName(recordBinding, alignmentName) <> 0
            alignmentName &= "_"
        Wend
        Dim alignmentIndent As String = fieldIndent
        If alignmentCarrierIsUnionMember = 0 Then _
            alignmentIndent = Space((indentLevel + 1) * 4)
        If fieldText <> "" Then fieldText &= Chr(10)
        fieldText &= alignmentIndent & alignmentName & _
            " As " & alignmentStorageType
        If alignmentCarrierIsUnionMember = 0 Then _
            fieldText &= Chr(10) & Space(indentLevel * 4) & "End Union"
    End If
    Return fieldText
End Function

Private Sub WriteC2fbOutputTextLines( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByVal text As String _
)
    Dim lineStart As Long = 1
    While lineStart <= Len(text)
        Dim lineEnd As Long = InStr(lineStart, text, Chr(10))
        If lineEnd = 0 Then lineEnd = Len(text) + 1
        WriteC2fbOutputLine( _
            outputFile, Mid(text, lineStart, lineEnd - lineStart))
        lineStart = lineEnd + 1
    Wend
End Sub

Private Sub FormatC2fbRecordBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef recordBinding As C2fbRecordBindingModel _
)
    Dim sourceCompoundName As String = "Type"
    If recordBinding.isUnion <> 0 Then sourceCompoundName = "Union"
    Dim alignedWrapper As Long = CInt(recordBinding.alignmentValue > 1) * -1
    Dim compoundName As String = sourceCompoundName
    If alignedWrapper <> 0 Then compoundName = "Union"
    Dim recordHeader As String = compoundName & " " & recordBinding.freeBasicName
    If alignedWrapper = 0 AndAlso recordBinding.isPacked <> 0 Then
        recordHeader &= " Field = 1"
    ElseIf alignedWrapper = 0 Then
        Select Case recordBinding.packValue
            Case 1, 2, 4, 8, 16
            recordHeader &= " Field = " & Trim(Str(recordBinding.packValue))
        End Select
    End If
    WriteC2fbOutputLine(outputFile, recordHeader)
    Dim indentLevel As Long = 1
    If alignedWrapper <> 0 Then
        Dim innerTypeHeader As String = "    Type"
        If recordBinding.isPacked <> 0 AndAlso recordBinding.packValue = 0 Then
            innerTypeHeader &= " Field = 1"
        ElseIf recordBinding.packValue > 0 Then
            innerTypeHeader &= " Field = " & Trim(Str(recordBinding.packValue))
        End If
        WriteC2fbOutputLine(outputFile, innerTypeHeader)
        indentLevel = 2
        If recordBinding.isUnion <> 0 Then
            Dim innerUnionHeader As String = "        Union"
            If recordBinding.isPacked <> 0 AndAlso recordBinding.packValue = 0 Then
                innerUnionHeader &= " Field = 1"
            ElseIf recordBinding.packValue > 0 Then
                innerUnionHeader &= " Field = " & Trim(Str(recordBinding.packValue))
            End If
            WriteC2fbOutputLine(outputFile, innerUnionHeader)
            indentLevel = 3
        End If
    End If
    Dim unionArrayElementCount As Long = _
        C2fbRecordBindingUnionArrayInitializerCount(recordBinding)
    If unionArrayElementCount > 0 Then
        Dim overlayPackValue As Long = recordBinding.packValue
        If recordBinding.isPacked <> 0 AndAlso overlayPackValue = 0 Then _
            overlayPackValue = 1
        Dim overlayHeader As String = Space(indentLevel * 4) & "Type"
        Select Case overlayPackValue
        Case 1, 2, 4, 8, 16
            overlayHeader &= " Field = " & Trim(Str(overlayPackValue))
        End Select
        WriteC2fbOutputLine(outputFile, overlayHeader)
        For elementIndex As Long = 0 To unionArrayElementCount - 1
            Dim elementName As String = _
                "c2fb_array_initializer_element_" & Trim(Str(elementIndex))
            While C2fbRecordBindingHasFieldName(recordBinding, elementName) <> 0
                elementName &= "_"
            Wend
            WriteC2fbOutputLine( _
                outputFile, Space((indentLevel + 1) * 4) & elementName & _
                " As " & recordBinding.items(0).fieldType)
        Next
        WriteC2fbOutputLine( _
            outputFile, Space(indentLevel * 4) & "End Type")
    End If
    If recordBinding.itemCount > 0 Then
        Dim aggregateLevel As Long = 0
        Dim aggregateIsUnionStack(0 To recordBinding.itemCount) As Long
        aggregateIsUnionStack(0) = recordBinding.isUnion
        For itemIndex As Long = 0 To recordBinding.itemCount - 1
            With recordBinding.items(itemIndex)
                Select Case .kind
                Case C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN
                    Dim nestedName As String = "Type"
                    If .isUnion <> 0 Then nestedName = "Union"
                    Dim nestedHeader As String = nestedName
                    Select Case .packValue
        Case 1, 2, 4, 8, 16
                        nestedHeader &= " Field = " & Trim(Str(.packValue))
                    End Select
                    WriteC2fbOutputLine( _
                        outputFile, Space(indentLevel * 4) & nestedHeader)
                    indentLevel += 1
                    aggregateLevel += 1
                    aggregateIsUnionStack(aggregateLevel) = .isUnion
                Case C2FB_RECORD_BINDING_ITEM_ANONYMOUS_END
                    If indentLevel > 1 Then indentLevel -= 1
                    Dim nestedName As String = "Type"
                    If .isUnion <> 0 Then nestedName = "Union"
                    WriteC2fbOutputLine( _
                        outputFile, Space(indentLevel * 4) & "End " & nestedName)
                    If aggregateLevel > 0 Then aggregateLevel -= 1
                Case C2FB_RECORD_BINDING_ITEM_FIELD
                    If .isArraySizeHinted <> 0 Then _
                        WriteC2fbOutputLine( _
                            outputFile, Space(indentLevel * 4) & _
                            "' C flexible array member size is expanded by --array-size: " & _
                            .name & "=" & Trim(Str(.arrayCount)))
                    WriteC2fbOutputTextLines( _
                        outputFile, C2fbRecordBindingFieldDeclarationText( _
                            recordBinding, itemIndex, .name, .fieldType, _
                            .arrayCount, .arrayBounds, .alignmentStorageType, _
                            IIf(.packValue > 0, .packValue, recordBinding.packValue), _
                            .isBitField, .bitWidth, _
                            aggregateIsUnionStack(aggregateLevel), indentLevel))
                Case C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY
                    If .zeroArrayStorageName <> "" Then
                        WriteC2fbOutputLine( _
                            outputFile, Space(indentLevel * 4) & _
                            "' synthetic flexible-array element preserves tail alignment")
                        WriteC2fbOutputLine( _
                            outputFile, Space(indentLevel * 4) & _
                            .zeroArrayStorageName & " As " & .fieldType)
                    Else
                        WriteC2fbOutputLine( _
                            outputFile, Space(indentLevel * 4) & _
                            "' trailing C byte array omitted; use " & _
                            .zeroArrayAccessorName & "(recordPtr)")
                    End If
                End Select
            End With
        Next
    Else
        For fieldIndex As Long = 0 To recordBinding.fieldCount - 1
            With recordBinding.fields(fieldIndex)
                WriteC2fbOutputTextLines( _
                    outputFile, C2fbRecordBindingFieldDeclarationText( _
                        recordBinding, fieldIndex, .name, .fieldType, _
                        .arrayCount, .arrayBounds, .alignmentStorageType, _
                        0, 0, 0, recordBinding.isUnion, indentLevel))
            End With
        Next
    End If
    If alignedWrapper <> 0 Then
        If recordBinding.isUnion <> 0 Then _
            WriteC2fbOutputLine(outputFile, "        End Union")
        WriteC2fbOutputLine(outputFile, "    End Type")
        Dim alignmentFieldName As String = "_c2fb_alignment_storage"
        Do
            Dim nameConflict As Long = 0
            For itemIndex As Long = 0 To recordBinding.itemCount - 1
                If recordBinding.items(itemIndex).kind = _
                       C2FB_RECORD_BINDING_ITEM_FIELD AndAlso _
                   LCase(recordBinding.items(itemIndex).name) = _
                       LCase(alignmentFieldName) Then
                    nameConflict = -1
                    Exit For
                End If
            Next
            If nameConflict = 0 Then Exit Do
            alignmentFieldName &= "_"
        Loop
        Dim alignmentStorageType As String = "LongInt"
        Select Case recordBinding.alignmentValue
        Case 2: alignmentStorageType = "Short"
        Case 4: alignmentStorageType = "Long"
        Case 16: alignmentStorageType = "Integer<128>"
        End Select
        WriteC2fbOutputLine(outputFile, "    " & alignmentFieldName & _
            " As " & alignmentStorageType)
    End If
    WriteC2fbOutputLine(outputFile, "End " & compoundName)
    For itemIndex As Long = 0 To recordBinding.itemCount - 1
        With recordBinding.items(itemIndex)
            If .kind <> C2FB_RECORD_BINDING_ITEM_ZERO_ARRAY Then Continue For
            Dim elementPointerType As String = .fieldType & " Ptr"
            Dim tailAddress As String
            If .zeroArrayStorageName <> "" Then
                tailAddress = "Cast(UByte Ptr, @((c2fb_zero_array_record_ptr)->" & _
                    .zeroArrayStorageName & "))"
            ElseIf .zeroArrayPreviousFieldName = "" Then
                tailAddress = "Cast(UByte Ptr, c2fb_zero_array_record_ptr)"
            ElseIf .zeroArrayPreviousArrayCount > 0 Then
                Dim previousElement As String = _
                    "(c2fb_zero_array_record_ptr)->" & _
                    .zeroArrayPreviousFieldName & "(0)"
                tailAddress = "Cast(UByte Ptr, @(" & previousElement & ")) + (" & _
                    "SizeOf(" & previousElement & ") * " & _
                    Trim(Str(.zeroArrayPreviousArrayCount)) & ")"
            Else
                tailAddress = "Cast(UByte Ptr, @((c2fb_zero_array_record_ptr)->" & _
                    .zeroArrayPreviousFieldName & ")) + SizeOf((" & _
                    "c2fb_zero_array_record_ptr)->" & _
                    .zeroArrayPreviousFieldName & ")"
            End If
            WriteC2fbOutputLine(outputFile, "#define " & .zeroArrayAccessorName & _
                "(c2fb_zero_array_record_ptr) Cast(" & elementPointerType & _
                ", " & tailAddress & ")")
        End With
    Next
    WriteC2fbOutputLine(outputFile, "")
End Sub

Private Function C2fbSharedAbiTypeAliasGuard( _
    ByVal freeBasicName As String _
) As String
    Select Case LCase(freeBasicName)
    Case "c2fb_c_int": Return "__C2FB_ABI_TYPE_C_INT__"
    Case "c2fb_c_uint": Return "__C2FB_ABI_TYPE_C_UINT__"
    Case "c2fb_c_long": Return "__C2FB_ABI_TYPE_C_LONG__"
    Case "c2fb_c_ulong": Return "__C2FB_ABI_TYPE_C_ULONG__"
    Case "c2fb_int64": Return "__C2FB_ABI_TYPE_INT64__"
    Case "c2fb_uint64": Return "__C2FB_ABI_TYPE_UINT64__"
    Case "c2fb_size_t": Return "__C2FB_ABI_TYPE_SIZE_T__"
    End Select
    Return ""
End Function

Private Sub FormatC2fbTypeAlias( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef typeAlias As C2fbTypeAliasBindingModel _
)
    ' Generic bindings and body candidates share these aliases when a header
    ' is included before the candidate declarations.
    Dim guardName As String = C2fbSharedAbiTypeAliasGuard(typeAlias.freeBasicName)
    If guardName <> "" Then
        WriteC2fbOutputLine(outputFile, "#ifndef " & guardName)
        WriteC2fbOutputLine(outputFile, "#define " & guardName)
    End If
    Dim declarationText As String = _
        "Type " & typeAlias.freeBasicName & " As " & typeAlias.targetType
    If typeAlias.alignmentValue > 0 Then _
        declarationText &= " Field = " & Trim(Str(typeAlias.alignmentValue))
    WriteC2fbOutputLine(outputFile, declarationText)
    If guardName <> "" Then _
        WriteC2fbOutputLine(outputFile, "#endif")
End Sub

Private Sub WriteC2fbTypeAliasByName( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByVal freeBasicName As String, _
    ByVal targetType As String, _
    ByVal ifndefGuardName As String = "", _
    ByVal undefBeforeName As String = "" _
)
    Dim typeAlias As C2fbTypeAliasBindingModel
    typeAlias.freeBasicName = freeBasicName
    typeAlias.targetType = targetType
    WriteC2fbTypeAlias(outputFile, typeAlias, ifndefGuardName, undefBeforeName)
End Sub

Private Sub WriteC2fbAbiTypeAliases( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If translation.target.profile <> C2FB_TARGET_SQLITE Then
        WriteC2fbTypeAliasByName(outputFile, "c2fb_c_int", "Long")
        WriteC2fbTypeAliasByName(outputFile, "c2fb_c_uint", "ULong")
        If translation.genericC.policy.cLong32 <> 0 Then
            WriteC2fbTypeAliasByName(outputFile, "c2fb_c_long", "Long")
            WriteC2fbTypeAliasByName(outputFile, "c2fb_c_ulong", "ULong")
        Else
            WriteC2fbTypeAliasByName(outputFile, "c2fb_c_long", "CLong")
            WriteC2fbTypeAliasByName(outputFile, "c2fb_c_ulong", "CULong")
        End If
        WriteC2fbTypeAliasByName(outputFile, "c2fb_int64", "LongInt")
        WriteC2fbTypeAliasByName(outputFile, "c2fb_uint64", "ULongInt")
        Dim sizeType As String
        If translation.genericC.policy.typeOverrideCount > 0 Then
            For overrideIndex As Long = 0 To _
                    translation.genericC.policy.typeOverrideCount - 1
                If translation.genericC.policy.typeOverrides(overrideIndex).sourceName = _
                   "size_t" Then
                    sizeType = translation.genericC.policy.typeOverrides( _
                        overrideIndex).freeBasicType
                    Exit For
                End If
            Next
        End If
        If sizeType = "" Then sizeType = "UInteger"
        WriteC2fbTypeAliasByName(outputFile, "c2fb_size_t", sizeType)
    Else
        WriteC2fbTypeAliasByName(outputFile, "c2fb_c_int", "SQLITE_C_INT")
        WriteC2fbTypeAliasByName(outputFile, "c2fb_c_uint", "SQLITE_C_UINT")
        WriteC2fbTypeAliasByName(outputFile, "c2fb_c_long", "SQLITE_C_LONG")
        WriteC2fbTypeAliasByName(outputFile, "c2fb_c_ulong", "SQLITE_C_ULONG")
        WriteC2fbTypeAliasByName(outputFile, "c2fb_int64", "sqlite3_int64")
        WriteC2fbTypeAliasByName(outputFile, "c2fb_uint64", "sqlite3_uint64")
        WriteC2fbTypeAliasByName(outputFile, "c2fb_size_t", "SQLITE_SIZE_T")
    End If
End Sub

Private Sub FormatC2fbConstantBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef constantBinding As C2fbConstantBindingModel _
)
    Dim declaration As String = "Const " & constantBinding.freeBasicName
    If constantBinding.targetType <> "" Then _
        declaration &= " As " & constantBinding.targetType
    declaration &= " = " & constantBinding.valueExpression
    WriteC2fbOutputLine(outputFile, declaration)
End Sub

Private Sub FormatC2fbIntegerConstantArrayBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef binding As C2fbIntegerConstantArrayBindingModel _
)
    If binding.valueCount <= 0 OrElse _
       binding.valueCount > MAX_C2FB_INTEGER_ARRAY_VALUES OrElse _
       binding.valueCapacity < binding.valueCount Then Exit Sub

    Dim upperBound As Long = binding.lowerBound + binding.valueCount - 1
    WriteC2fbOutputLine( _
        outputFile, "Dim Shared As Const " & binding.elementType & " " & _
        binding.name & "(" & Trim(Str(binding.lowerBound)) & " To " & _
        Trim(Str(upperBound)) & ") = { _")
    Dim firstValue As Long = 0
    While firstValue < binding.valueCount
        Dim lastValue As Long = _
            firstValue + C2FB_INTEGER_ARRAY_VALUES_PER_LINE
        If lastValue > binding.valueCount Then lastValue = binding.valueCount
        Dim lineText As String = "    "
        For valueIndex As Long = firstValue To lastValue - 1
            If valueIndex > firstValue Then lineText &= ", "
            lineText &= Trim(Str(binding.values(valueIndex)))
        Next
        If lastValue < binding.valueCount Then
            lineText &= ", _"
        Else
            lineText &= " _"
        End If
        WriteC2fbOutputLine(outputFile, lineText)
        firstValue = lastValue
    Wend
    WriteC2fbOutputLine(outputFile, "}")
End Sub

Private Sub FormatC2fbMacroBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef macroBinding As C2fbMacroBindingModel _
)
    Dim signature As String = macroBinding.name
    If macroBinding.isFunctionLike <> 0 Then _
        signature &= "(" & macroBinding.parameters & ")"
    If macroBinding.isBlock <> 0 Then
        WriteC2fbOutputLine(outputFile, "#macro " & signature)
        If macroBinding.bodyText <> "" Then _
            WriteC2fbOutputLine(outputFile, macroBinding.bodyText)
        WriteC2fbOutputLine(outputFile, "#endmacro")
    Else
        Dim definition As String = "#define " & signature
        If macroBinding.bodyText <> "" Then definition &= " " & macroBinding.bodyText
        WriteC2fbOutputLine(outputFile, definition)
    End If
End Sub

Private Function C2fbDiagnosticSeverityName( _
    ByVal severity As C2fbDiagnosticSeverity _
) As String
    Select Case severity
    Case C2FB_DIAGNOSTIC_SEVERITY_WARNING: Return "warning"
    Case C2FB_DIAGNOSTIC_SEVERITY_ERROR: Return "error"
    Case Else: Return "unknown"
    End Select
End Function

Private Sub FormatC2fbDiagnostic( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef diagnostic As C2fbDiagnosticModel _
)
    Dim location As String
    If diagnostic.location.path <> "" Then location = diagnostic.location.path
    If diagnostic.location.line > 0 Then
        location &= "(" & Trim(Str(diagnostic.location.line))
        If diagnostic.location.column > 0 Then _
            location &= "," & Trim(Str(diagnostic.location.column))
        location &= ")"
    End If
    If location <> "" Then location &= ": "
    WriteC2fbOutputLine( _
        outputFile, "' c2fb " & C2fbDiagnosticSeverityName(diagnostic.severity) & " [" & _
        diagnostic.code & "] " & location & diagnostic.message)
End Sub

Private Sub FormatC2fbSkippedDiagnostic( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef diagnostic As C2fbDiagnosticModel _
)
    WriteC2fbOutputLine(outputFile, "' c2fb skipped " & diagnostic.message)
End Sub

Private Sub WriteC2fbDiagnosticConsole( _
    ByRef diagnostic As C2fbDiagnosticModel _
)
    If diagnostic.severity = C2FB_DIAGNOSTIC_SEVERITY_ERROR Then
        Print "c2fb: " & diagnostic.message
    ElseIf diagnostic.severity = C2FB_DIAGNOSTIC_SEVERITY_WARNING Then
        Print "C2FB rejected " & diagnostic.message
    Else
        Print "c2fb: invalid diagnostic severity"
    End If
End Sub

Private Sub WriteC2fbVerboseConsole( _
    ByVal verbosityLevel As Long, ByVal requiredLevel As Long, _
    ByVal message As String _
)
    If verbosityLevel < requiredLevel Then Exit Sub
    Print "c2fb: " & message
End Sub

Private Sub WriteC2fbOutputItem( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef outputItem As C2fbOutputItemModel _
)
    If outputItem.undefBeforeName <> "" Then _
        WriteC2fbOutputLine(outputFile, "#undef " & outputItem.undefBeforeName)
    If outputItem.ifndefGuardName <> "" Then _
        WriteC2fbOutputLine(outputFile, "#ifndef " & outputItem.ifndefGuardName)
    Select Case outputItem.kind
    Case C2FB_OUTPUT_ITEM_PROCEDURE
        FormatC2fbProcedureBinding(outputFile, outputItem.procedureBinding)
    Case C2FB_OUTPUT_ITEM_OBJECT
        FormatC2fbObjectBinding(outputFile, outputItem.objectBinding)
    Case C2FB_OUTPUT_ITEM_RECORD
        FormatC2fbRecordBinding(outputFile, outputItem.recordBinding)
    Case C2FB_OUTPUT_ITEM_TYPE_ALIAS
        FormatC2fbTypeAlias(outputFile, outputItem.typeAlias)
    Case C2FB_OUTPUT_ITEM_CONSTANT
        FormatC2fbConstantBinding(outputFile, outputItem.constantBinding)
    Case C2FB_OUTPUT_ITEM_MACRO
        FormatC2fbMacroBinding(outputFile, outputItem.macroBinding)
    Case C2FB_OUTPUT_ITEM_DIAGNOSTIC
        FormatC2fbDiagnostic(outputFile, outputItem.diagnostic)
    Case C2FB_OUTPUT_ITEM_SKIPPED_DIAGNOSTIC
        FormatC2fbSkippedDiagnostic(outputFile, outputItem.diagnostic)
    Case C2FB_OUTPUT_ITEM_INTEGER_CONSTANT_ARRAY
        FormatC2fbIntegerConstantArrayBinding( _
            outputFile, outputItem.integerConstantArrayBinding)
    End Select
    If outputItem.ifndefGuardName <> "" Then _
        WriteC2fbOutputLine(outputFile, "#endif")
End Sub

Private Sub WriteC2fbProcedureBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef procedureBinding As C2fbProcedureBindingModel, _
    ByVal ifndefGuardName As String = "", _
    ByVal undefBeforeName As String = "" _
)
    Dim outputItem As C2fbOutputItemModel
    outputItem.kind = C2FB_OUTPUT_ITEM_PROCEDURE
    outputItem.ifndefGuardName = ifndefGuardName
    outputItem.undefBeforeName = undefBeforeName
    outputItem.procedureBinding = procedureBinding
    WriteC2fbOutputItem(outputFile, outputItem)
End Sub

Private Sub WriteC2fbObjectBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef objectBinding As C2fbObjectBindingModel, _
    ByVal ifndefGuardName As String = "", _
    ByVal undefBeforeName As String = "" _
)
    Dim outputItem As C2fbOutputItemModel
    outputItem.kind = C2FB_OUTPUT_ITEM_OBJECT
    outputItem.ifndefGuardName = ifndefGuardName
    outputItem.undefBeforeName = undefBeforeName
    outputItem.objectBinding = objectBinding
    WriteC2fbOutputItem(outputFile, outputItem)
End Sub

Private Sub WriteC2fbRecordBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef recordBinding As C2fbRecordBindingModel, _
    ByVal ifndefGuardName As String = "", _
    ByVal undefBeforeName As String = "" _
)
    Dim outputItem As C2fbOutputItemModel
    outputItem.kind = C2FB_OUTPUT_ITEM_RECORD
    outputItem.ifndefGuardName = ifndefGuardName
    outputItem.undefBeforeName = undefBeforeName
    outputItem.recordBinding = recordBinding
    WriteC2fbOutputItem(outputFile, outputItem)
End Sub

Private Sub WriteC2fbTypeAlias( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef typeAlias As C2fbTypeAliasBindingModel, _
    ByVal ifndefGuardName As String, _
    ByVal undefBeforeName As String _
)
    Dim outputItem As C2fbOutputItemModel
    outputItem.kind = C2FB_OUTPUT_ITEM_TYPE_ALIAS
    outputItem.ifndefGuardName = ifndefGuardName
    outputItem.undefBeforeName = undefBeforeName
    outputItem.typeAlias = typeAlias
    WriteC2fbOutputItem(outputFile, outputItem)
End Sub

Private Sub WriteC2fbConstantBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef constantBinding As C2fbConstantBindingModel, _
    ByVal ifndefGuardName As String = "", _
    ByVal undefBeforeName As String = "" _
)
    Dim outputItem As C2fbOutputItemModel
    outputItem.kind = C2FB_OUTPUT_ITEM_CONSTANT
    outputItem.ifndefGuardName = ifndefGuardName
    outputItem.undefBeforeName = undefBeforeName
    outputItem.constantBinding = constantBinding
    WriteC2fbOutputItem(outputFile, outputItem)
End Sub

Private Sub WriteC2fbMacroBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef macroBinding As C2fbMacroBindingModel, _
    ByVal ifndefGuardName As String, _
    ByVal undefBeforeName As String _
)
    Dim outputItem As C2fbOutputItemModel
    outputItem.kind = C2FB_OUTPUT_ITEM_MACRO
    outputItem.ifndefGuardName = ifndefGuardName
    outputItem.undefBeforeName = undefBeforeName
    outputItem.macroBinding = macroBinding
    WriteC2fbOutputItem(outputFile, outputItem)
End Sub

Private Function WriteC2fbIntegerConstantArrayBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef binding As C2fbIntegerConstantArrayBindingModel _
) As Long
    If binding.name = "" OrElse binding.elementType = "" OrElse _
       binding.valueCount <= 0 OrElse _
       binding.valueCount > MAX_C2FB_INTEGER_ARRAY_VALUES OrElse _
       binding.valueCapacity < binding.valueCount Then Return 0
    Dim outputItem As C2fbOutputItemModel
    outputItem.kind = C2FB_OUTPUT_ITEM_INTEGER_CONSTANT_ARRAY
    outputItem.integerConstantArrayBinding = binding
    WriteC2fbOutputItem(outputFile, outputItem)
    Return -1
End Function

Private Sub WriteC2fbDiagnostic( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef diagnostic As C2fbDiagnosticModel _
)
    Dim outputItem As C2fbOutputItemModel
    outputItem.kind = C2FB_OUTPUT_ITEM_DIAGNOSTIC
    outputItem.diagnostic = diagnostic
    WriteC2fbOutputItem(outputFile, outputItem)
End Sub

Private Sub WriteC2fbSkippedDiagnostic( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef diagnostic As C2fbDiagnosticModel _
)
    Dim outputItem As C2fbOutputItemModel
    outputItem.kind = C2FB_OUTPUT_ITEM_SKIPPED_DIAGNOSTIC
    outputItem.diagnostic = diagnostic
    WriteC2fbOutputItem(outputFile, outputItem)
End Sub

/' end of c2fb_output.bi '/
