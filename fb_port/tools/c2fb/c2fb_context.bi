/'
    Project: C2FB shared translation context
    ----------------------------------------

    File: c2fb_context.bi

    Purpose:

        Configure the active target and source-map profile for one translation.

    Responsibilities:

        - Validate typed target and source-map selections.
        - Install both selections together in the translation context.

    This file intentionally does NOT contain:

        - Command-line parsing, source scanning, or conversion policy.
        - Translation-unit, project-catalog, or diagnostic reset logic.
'/

Private Function C2fbTargetProfileIsValid( _
    ByVal targetProfile As C2fbTargetProfile _
) As Long
    Select Case targetProfile
    Case C2FB_TARGET_SQLITE, C2FB_TARGET_GENERIC
        Return -1
    Case Else
        Return 0
    End Select
End Function

Private Sub ResetC2fbTranslationTarget( _
    ByRef translation As C2fbTranslationContext _
)
    translation.target.profile = C2FB_TARGET_INVALID
    translation.target.sourceMapMode = C2FB_SOURCE_MAP_DISABLED
End Sub

Private Function ConfigureC2fbTranslationTarget( _
    ByRef translation As C2fbTranslationContext, _
    ByVal targetProfile As C2fbTargetProfile, _
    ByVal sourceMapMode As C2fbSourceMapMode _
) As Long
    If C2fbTargetProfileIsValid(targetProfile) = 0 Then Return 0

    Select Case sourceMapMode
    Case C2FB_SOURCE_MAP_DISABLED, C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS
    Case Else
        Return 0
    End Select

    translation.target.profile = targetProfile
    translation.target.sourceMapMode = sourceMapMode
    Return -1
End Function

/' end of c2fb_context.bi '/
