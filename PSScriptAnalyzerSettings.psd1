@{
    IncludeDefaultRules = $true

    ExcludeRules = @(
        # Tray actions are interactive functions, not PowerShell cmdlets.
        'PSUseShouldProcessForStateChangingFunctions'

        # These functions surface collections, and singular nouns would make their names less clear.
        'PSUseSingularNouns'
    )
}
