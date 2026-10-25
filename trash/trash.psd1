@{
    RootModule           = 'trash.psm1'
    ModuleVersion        = '0.2.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID                 = 'd5f837ac-96a1-4df2-ad2b-0bd274bd0dec'
    Author               = 'An Long'
    Copyright            = '(c) 2026 An Long. Licensed under the MIT License.'
    Description          = 'Move files to the Windows Recycle Bin, and list, restore, purge or empty its contents. Provides the short "trash" command.'
    PowerShellVersion    = '5.1'

    FunctionsToExport    = @('Move-ItemToTrash', 'Get-TrashItem', 'Restore-TrashItem', 'Remove-TrashItem', 'Clear-Trash', 'trash')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags = @('Trash', 'RecycleBin', 'Recycle', 'Delete', 'Restore', 'Windows', 'PSEdition_Desktop', 'PSEdition_Core')
            LicenseUri = 'https://github.com/aisk/trash.ps1/blob/main/LICENSE'
            ProjectUri = 'https://github.com/aisk/trash.ps1'
        }
    }
}
