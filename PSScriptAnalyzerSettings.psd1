@{
    IncludeDefaultRules = $true

    ExcludeRules = @(
        # Install.ps1 and Uninstall.ps1 legitimately write console output.
        'PSAvoidUsingWriteHost'

        # Tray actions are interactive functions, not PowerShell cmdlets.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
