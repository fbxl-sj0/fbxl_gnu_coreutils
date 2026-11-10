/'
    Project: C2FB name lists
    ------------------------

    File: c2fb_names.bi

    Purpose:

        Provide bounded lookup indexes for FreeBASIC project names.

    Responsibilities:

        - Compare name sets using FreeBASIC's case-insensitive identifier behavior.
        - Maintain bounded hash indexes for project names and call signatures.
        - Support shared lookup across catalogs, symbols, candidates, and output names.

    This file intentionally does NOT contain:

        - C case-sensitive declaration identity or source parsing.
        - Name allocation, mutation, or symbol registration.
'/

Private Function C2fbNameListContains( _
    names() As String, _
    ByVal nameCount As Long, _
    ByVal targetName As String _
) As Long
    For nameIndex As Long = 0 To nameCount - 1
        If LCase(names(nameIndex)) = LCase(targetName) Then Return -1
    Next
    Return 0
End Function

Private Function C2fbDelimitedNameListContains( _
    ByVal delimitedNames As String, ByVal targetName As String _
) As Long
    If delimitedNames = "" OrElse targetName = "" Then Return 0
    Return CInt(InStr( _
        LCase(delimitedNames), "|" & LCase(targetName) & "|") <> 0) * -1
End Function

Private Sub ResetC2fbNameSet(ByRef nameSet As C2fbNameSetModel)
    nameSet.itemCount = 0
    nameSet.capacity = 256
    ReDim nameSet.slots(0 To nameSet.capacity - 1)
End Sub

Private Function C2fbNameHashIndex( _
    ByVal key As String, ByVal capacity As Long _
) As Long
    Dim hashValue As ULongInt = C2FB_NAME_HASH_SEED
    For position As Long = 1 To Len(key)
        hashValue = (hashValue Xor _
            CULngInt(Asc(key, position) And 255)) * _
            C2FB_NAME_HASH_MULTIPLIER
        hashValue = hashValue And C2FB_NAME_HASH_MASK
    Next

    ' Final mixing improves low-bit distribution for power-of-two table sizes.
    hashValue = hashValue Xor (hashValue Shr 16)
    hashValue = (hashValue * C2FB_NAME_HASH_FINAL_MULTIPLIER_1) And _
        C2FB_NAME_HASH_MASK
    hashValue = hashValue Xor (hashValue Shr 13)
    hashValue = (hashValue * C2FB_NAME_HASH_FINAL_MULTIPLIER_2) And _
        C2FB_NAME_HASH_MASK
    hashValue = hashValue Xor (hashValue Shr 16)
    Return CInt(hashValue Mod CULngInt(capacity))
End Function

Private Function C2fbNameSetHashIndex( _
    ByVal canonicalName As String, ByVal capacity As Long _
) As Long
    Return C2fbNameHashIndex(canonicalName, capacity)
End Function

Private Function C2fbNameSetContainsCanonical( _
    ByRef nameSet As C2fbNameSetModel, ByVal canonicalName As String _
) As Long
    If nameSet.capacity <= 0 OrElse canonicalName = "" Then Return 0
    Dim slotIndex As Long = C2fbNameSetHashIndex( _
        canonicalName, nameSet.capacity)
    For probeIndex As Long = 0 To nameSet.capacity - 1
        Dim storedName As String = nameSet.slots(slotIndex)
        If storedName = "" Then Return 0
        If storedName = canonicalName Then Return -1
        slotIndex += 1
        If slotIndex >= nameSet.capacity Then slotIndex = 0
    Next
    Return 0
End Function

Private Function C2fbNameSetContains( _
    ByRef nameSet As C2fbNameSetModel, ByVal targetName As String _
) As Long
    If targetName = "" Then Return 0
    Return C2fbNameSetContainsCanonical(nameSet, LCase(targetName))
End Function

Private Function InsertC2fbNameSetCanonical( _
    ByRef nameSet As C2fbNameSetModel, ByVal canonicalName As String _
) As Long
    If nameSet.capacity <= 0 OrElse canonicalName = "" Then Return 0
    Dim slotIndex As Long = C2fbNameSetHashIndex( _
        canonicalName, nameSet.capacity)
    For probeIndex As Long = 0 To nameSet.capacity - 1
        If nameSet.slots(slotIndex) = "" Then
            nameSet.slots(slotIndex) = canonicalName
            nameSet.itemCount += 1
            Return -1
        End If
        If nameSet.slots(slotIndex) = canonicalName Then Return 1
        slotIndex += 1
        If slotIndex >= nameSet.capacity Then slotIndex = 0
    Next
    Return 0
End Function

Private Function AddC2fbNameSet( _
    ByRef nameSet As C2fbNameSetModel, ByVal sourceName As String _
) As Long
    If sourceName = "" Then Return 0
    Dim canonicalName As String = LCase(sourceName)
    If C2fbNameSetContainsCanonical(nameSet, canonicalName) <> 0 Then Return 1
    If nameSet.capacity <= 0 Then ResetC2fbNameSet(nameSet)

    If (nameSet.itemCount + 1) * 10 >= nameSet.capacity * 7 Then
        If nameSet.capacity >= MAX_FUNCTIONS * 2 Then Return 0
        Dim oldCapacity As Long = nameSet.capacity
        Dim oldSlots() As String
        ReDim oldSlots(0 To oldCapacity - 1)
        For slotIndex As Long = 0 To oldCapacity - 1
            oldSlots(slotIndex) = nameSet.slots(slotIndex)
        Next

        nameSet.capacity *= 2
        ReDim nameSet.slots(0 To nameSet.capacity - 1)
        nameSet.itemCount = 0
        For slotIndex As Long = 0 To oldCapacity - 1
            If oldSlots(slotIndex) <> "" AndAlso _
               InsertC2fbNameSetCanonical(nameSet, oldSlots(slotIndex)) = 0 Then _
                Return 0
        Next
    End If
    Return InsertC2fbNameSetCanonical(nameSet, canonicalName)
End Function

Private Function C2fbStringIndexHash( _
    ByVal key As String, ByVal capacity As Long _
) As Long
    Return C2fbNameHashIndex(key, capacity)
End Function

Private Sub ResetC2fbStringIndexMap( _
    ByRef indexMap As C2fbStringIndexMapModel _
)
    indexMap.itemCount = 0
    indexMap.capacity = 256
    ReDim indexMap.keys(0 To indexMap.capacity - 1)
    ReDim indexMap.values(0 To indexMap.capacity - 1)
End Sub

Private Function C2fbStringIndexMapLookup( _
    ByRef indexMap As C2fbStringIndexMapModel, ByVal key As String _
) As Long
    If indexMap.capacity <= 0 OrElse key = "" Then Return -1
    Dim slotIndex As Long = C2fbStringIndexHash(key, indexMap.capacity)
    For probeIndex As Long = 0 To indexMap.capacity - 1
        If indexMap.keys(slotIndex) = "" Then Return -1
        If indexMap.keys(slotIndex) = key Then Return indexMap.values(slotIndex)
        slotIndex += 1
        If slotIndex >= indexMap.capacity Then slotIndex = 0
    Next
    Return -1
End Function

Private Function InsertC2fbStringIndexMapEntry( _
    ByRef indexMap As C2fbStringIndexMapModel, ByVal key As String, _
    ByVal value As Long _
) As Long
    If indexMap.capacity <= 0 OrElse key = "" Then Return 0
    Dim slotIndex As Long = C2fbStringIndexHash(key, indexMap.capacity)
    For probeIndex As Long = 0 To indexMap.capacity - 1
        If indexMap.keys(slotIndex) = "" Then
            indexMap.keys(slotIndex) = key
            indexMap.values(slotIndex) = value
            indexMap.itemCount += 1
            Return -1
        End If
        If indexMap.keys(slotIndex) = key Then Return 1
        slotIndex += 1
        If slotIndex >= indexMap.capacity Then slotIndex = 0
    Next
    Return 0
End Function

Private Function AddC2fbStringIndexMapEntry( _
    ByRef indexMap As C2fbStringIndexMapModel, ByVal key As String, _
    ByVal value As Long _
) As Long
    If key = "" Then Return 0
    If C2fbStringIndexMapLookup(indexMap, key) >= 0 Then Return 1
    If indexMap.capacity <= 0 Then ResetC2fbStringIndexMap(indexMap)

    If (indexMap.itemCount + 1) * 10 >= indexMap.capacity * 7 Then
        If indexMap.capacity >= MAX_C2FB_STRING_INDEX_MAP_CAPACITY Then Return 0
        Dim oldCapacity As Long = indexMap.capacity
        Dim oldKeys() As String
        Dim oldValues() As Long
        ReDim oldKeys(0 To oldCapacity - 1)
        ReDim oldValues(0 To oldCapacity - 1)
        For slotIndex As Long = 0 To oldCapacity - 1
            oldKeys(slotIndex) = indexMap.keys(slotIndex)
            oldValues(slotIndex) = indexMap.values(slotIndex)
        Next

        indexMap.capacity *= 2
        ReDim indexMap.keys(0 To indexMap.capacity - 1)
        ReDim indexMap.values(0 To indexMap.capacity - 1)
        indexMap.itemCount = 0
        For slotIndex As Long = 0 To oldCapacity - 1
            If oldKeys(slotIndex) <> "" AndAlso _
               InsertC2fbStringIndexMapEntry( _
                   indexMap, oldKeys(slotIndex), oldValues(slotIndex)) = 0 Then _
                Return 0
        Next
    End If
    Return InsertC2fbStringIndexMapEntry(indexMap, key, value)
End Function

/' end of c2fb_names.bi '/
