Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    throw 'The trash module only supports Windows.'
}

if (-not ('TrashPs.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TrashPs {
    public static class Native {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SHFILEOPSTRUCT {
            public IntPtr hwnd;
            public uint wFunc;
            public string pFrom;
            public string pTo;
            public ushort fFlags;
            [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
            public IntPtr hNameMappings;
            public string lpszProgressTitle;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHEmptyRecycleBin(IntPtr hwnd, string root, uint flags);

        [DllImport("shell32.dll")]
        private static extern bool SHUpdateRecycleBinIcon();

        private const uint FO_DELETE = 3;
        private const ushort FOF_SILENT = 0x0004;
        private const ushort FOF_NOCONFIRMATION = 0x0010;
        private const ushort FOF_ALLOWUNDO = 0x0040;
        private const ushort FOF_NOERRORUI = 0x0400;
        // Ask before destroying a file that cannot be recycled (too large, network drive, ...).
        private const ushort FOF_WANTNUKEWARNING = 0x4000;

        private const uint SHERB_NOCONFIRMATION = 0x1;
        private const uint SHERB_NOPROGRESSUI = 0x2;
        private const uint SHERB_NOSOUND = 0x4;

        // Returns 0 on success, -1 if the user aborted, or the SHFileOperation error code.
        public static int Recycle(string fullPath) {
            var op = new SHFILEOPSTRUCT {
                wFunc = FO_DELETE,
                pFrom = fullPath + "\0\0",
                fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_WANTNUKEWARNING,
            };
            int ret = SHFileOperation(ref op);
            if (ret == 0 && op.fAnyOperationsAborted) return -1;
            return ret;
        }

        public static int EmptyRecycleBin() {
            return SHEmptyRecycleBin(IntPtr.Zero, null,
                SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND);
        }

        public static void UpdateIcon() {
            SHUpdateRecycleBinIcon();
        }
    }
}
'@
}

Update-TypeData -TypeName 'TrashPs.Item' -DefaultDisplayPropertySet Id, DeletedAt, Size, OriginalPath -Force

#region Private helpers

# Parse a $I metadata file. Format version 1 (Vista/7) stores a fixed 260-char
# path, version 2 (Windows 10+) stores a length-prefixed path.
function Read-TrashInfo([System.IO.FileInfo] $InfoFile) {
    $bytes = [System.IO.File]::ReadAllBytes($InfoFile.FullName)
    if ($bytes.Length -lt 24) { return }
    $version = [BitConverter]::ToInt64($bytes, 0)
    $size = [BitConverter]::ToInt64($bytes, 8)
    $deletedAt = [DateTime]::FromFileTime([BitConverter]::ToInt64($bytes, 16))
    switch ($version) {
        1 { $raw = [Text.Encoding]::Unicode.GetString($bytes, 24, [Math]::Min(520, $bytes.Length - 24)) }
        2 {
            if ($bytes.Length -lt 28) { return }
            $chars = [BitConverter]::ToInt32($bytes, 24)
            $raw = [Text.Encoding]::Unicode.GetString($bytes, 28, [Math]::Min($chars * 2, $bytes.Length - 28))
        }
        default { return }
    }
    $originalPath = $raw.Split([char]0)[0]

    $dataPath = Join-Path $InfoFile.DirectoryName ('$R' + $InfoFile.Name.Substring(2))
    if (-not (Test-Path -LiteralPath $dataPath)) { return }

    [pscustomobject]@{
        PSTypeName   = 'TrashPs.Item'
        Id           = $InfoFile.BaseName.Substring(2)
        Name         = Split-Path $originalPath -Leaf
        OriginalPath = $originalPath
        DeletedAt    = $deletedAt
        Size         = $size
        IsDirectory  = Test-Path -LiteralPath $dataPath -PathType Container
        DataPath     = $dataPath
        InfoPath     = $InfoFile.FullName
    }
}

function Test-TrashItemMatch($Item, [string[]] $Patterns) {
    foreach ($p in $Patterns) {
        if ($Item.Id -eq $p -or $Item.Name -like $p -or $Item.OriginalPath -like $p) { return $true }
    }
    $false
}

# Expand wildcards, but prefer a literal match so names containing [] still work.
function Resolve-TargetPath([string] $InputPath, [switch] $Literal) {
    if (Test-Path -LiteralPath $InputPath) {
        return (Get-Item -LiteralPath $InputPath -Force).FullName
    }
    $resolved = @(if (-not $Literal) { Resolve-Path -Path $InputPath -ErrorAction SilentlyContinue })
    if ($resolved.Count -eq 0) {
        Write-Error -Message "Cannot find path '$InputPath' because it does not exist." `
            -Category ObjectNotFound -TargetObject $InputPath
        return
    }
    $resolved | ForEach-Object { $_.ProviderPath }
}

# Resolve the items a Restore/Remove call acts on, from pipeline objects or patterns.
function Resolve-TrashItem($InputObject, [string[]] $Filter) {
    if ($InputObject) { return $InputObject }
    $items = @(Get-TrashItem -Filter $Filter)
    if ($items.Count -eq 0) {
        Write-Warning "No Recycle Bin item matches: $($Filter -join ', ')"
    }
    $items
}

#endregion

<#
.SYNOPSIS
    Move files or directories to the Recycle Bin.
.EXAMPLE
    Move-ItemToTrash foo.txt, *.log
.EXAMPLE
    Get-ChildItem *.tmp | Move-ItemToTrash
#>
function Move-ItemToTrash {
    [CmdletBinding(DefaultParameterSetName = 'Path', SupportsShouldProcess)]
    param(
        # Paths to recycle. Wildcards are supported.
        [Parameter(ParameterSetName = 'Path', Mandatory, Position = 0, ValueFromPipeline)]
        [string[]] $Path,

        # Paths to recycle, used exactly as typed.
        [Parameter(ParameterSetName = 'LiteralPath', Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('PSPath', 'FullName', 'LP')]
        [string[]] $LiteralPath
    )

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            $Path | ForEach-Object { Resolve-TargetPath $_ }
        }
        else {
            $LiteralPath | ForEach-Object { Resolve-TargetPath (Convert-Path -LiteralPath $_) -Literal }
        }
        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target, 'Move to Recycle Bin')) { continue }
            $ret = [TrashPs.Native]::Recycle($target)
            if ($ret -eq -1) {
                Write-Warning "Aborted: $target"
            }
            elseif ($ret -ne 0) {
                Write-Error -Message ("Failed to move '{0}' to Recycle Bin (code 0x{1:X})." -f $target, $ret) `
                    -TargetObject $target
            }
        }
    }
}

<#
.SYNOPSIS
    List items in the Recycle Bin of the current user.
.EXAMPLE
    Get-TrashItem *.log
    List items whose name or original path matches *.log.
#>
function Get-TrashItem {
    [CmdletBinding()]
    [OutputType('TrashPs.Item')]
    param(
        # Patterns matched against the Id, name or original path. Lists everything when omitted.
        [Parameter(Position = 0)]
        [string[]] $Filter
    )

    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $items = foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        $bin = Join-Path $drive.RootDirectory.FullName "`$Recycle.Bin\$sid"
        if (-not (Test-Path -LiteralPath $bin)) { continue }
        Get-ChildItem -LiteralPath $bin -Force -File -Filter '$I*' -ErrorAction SilentlyContinue |
            ForEach-Object { Read-TrashInfo $_ }
    }
    if ($Filter) { $items = $items | Where-Object { Test-TrashItemMatch $_ $Filter } }
    $items | Sort-Object DeletedAt -Descending
}

<#
.SYNOPSIS
    Restore Recycle Bin items to their original location.
.EXAMPLE
    Restore-TrashItem 'C:\work\*.txt'
.EXAMPLE
    Get-TrashItem report.docx | Select-Object -First 1 | Restore-TrashItem
    Restore the most recently deleted report.docx.
#>
function Restore-TrashItem {
    [CmdletBinding(DefaultParameterSetName = 'Filter', SupportsShouldProcess)]
    param(
        # Patterns matched against the Id, name or original path.
        [Parameter(ParameterSetName = 'Filter', Mandatory, Position = 0)]
        [string[]] $Filter,

        # Items from Get-TrashItem.
        [Parameter(ParameterSetName = 'InputObject', Mandatory, ValueFromPipeline)]
        [PSTypeName('TrashPs.Item')]
        [object[]] $InputObject
    )

    process {
        $restored = $false
        foreach ($item in Resolve-TrashItem $InputObject $Filter) {
            $dest = $item.OriginalPath
            if (Test-Path -LiteralPath $dest) {
                Write-Error -Message "Cannot restore '$dest' because it already exists." `
                    -Category ResourceExists -TargetObject $dest
                continue
            }
            if (-not $PSCmdlet.ShouldProcess($dest, 'Restore from Recycle Bin')) { continue }
            $parent = Split-Path $dest -Parent
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Move-Item -LiteralPath $item.DataPath -Destination $dest -ErrorAction Stop
            Remove-Item -LiteralPath $item.InfoPath -Force
            $restored = $true
        }
        if ($restored) { [TrashPs.Native]::UpdateIcon() }
    }
}

<#
.SYNOPSIS
    Permanently delete items from the Recycle Bin.
.EXAMPLE
    Remove-TrashItem 'C:\tmp\*' -Force
.EXAMPLE
    Get-TrashItem | Where-Object DeletedAt -lt (Get-Date).AddDays(-30) | Remove-TrashItem
#>
function Remove-TrashItem {
    [CmdletBinding(DefaultParameterSetName = 'Filter', SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        # Patterns matched against the Id, name or original path.
        [Parameter(ParameterSetName = 'Filter', Mandatory, Position = 0)]
        [string[]] $Filter,

        # Items from Get-TrashItem.
        [Parameter(ParameterSetName = 'InputObject', Mandatory, ValueFromPipeline)]
        [PSTypeName('TrashPs.Item')]
        [object[]] $InputObject,

        # Do not ask for confirmation.
        [switch] $Force
    )

    begin {
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
    }

    process {
        $removed = $false
        foreach ($item in Resolve-TrashItem $InputObject $Filter) {
            if (-not $PSCmdlet.ShouldProcess($item.OriginalPath, 'Permanently delete from Recycle Bin')) { continue }
            Remove-Item -LiteralPath $item.DataPath -Recurse -Force
            Remove-Item -LiteralPath $item.InfoPath -Force
            $removed = $true
        }
        if ($removed) { [TrashPs.Native]::UpdateIcon() }
    }
}

<#
.SYNOPSIS
    Empty the Recycle Bin on all drives.
#>
function Clear-Trash {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        # Do not ask for confirmation.
        [switch] $Force
    )

    if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
    if (-not $PSCmdlet.ShouldProcess('Recycle Bin', 'Empty')) { return }
    $ret = [TrashPs.Native]::EmptyRecycleBin()
    # E_UNEXPECTED (0x8000FFFF) is returned when the Recycle Bin is already empty.
    if ($ret -ne 0 -and $ret -ne -2147418113) {
        Write-Error ("Failed to empty Recycle Bin (HRESULT 0x{0:X8})." -f $ret)
    }
}

<#
.SYNOPSIS
    Short command for everyday Recycle Bin operations.

.DESCRIPTION
    By default every given path is moved to the Recycle Bin. The switches select
    another operation, each forwarding to the matching command of this module:

        trash <path...>              Move-ItemToTrash
        trash -Permanent <path...>   Remove-Item -Recurse -Force
        trash -List [pattern...]     Get-TrashItem
        trash -Restore <pattern...>  Restore-TrashItem
        trash -Purge <pattern...>    Remove-TrashItem
        trash -Empty                 Clear-Trash

    Patterns are matched against the Id, name or original path of Recycle Bin items.

.EXAMPLE
    trash foo.txt bar\ *.log

.EXAMPLE
    trash -List *.log | trash -Restore
#>
function trash {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Paths to recycle, or patterns for -List, -Restore and -Purge.
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, ValueFromRemainingArguments)]
        [Alias('FullName', 'Id')]
        [string[]] $Path,

        # Delete directly instead of moving to the Recycle Bin.
        [switch] $Permanent,

        # List Recycle Bin items.
        [Alias('l')]
        [switch] $List,

        # Restore matching items to their original location.
        [Alias('r')]
        [switch] $Restore,

        # Permanently delete matching items from the Recycle Bin.
        [switch] $Purge,

        # Empty the Recycle Bin.
        [Alias('e')]
        [switch] $Empty,

        # Do not ask for confirmation with -Purge and -Empty.
        [switch] $Force
    )

    # A single parameter set keeps `trash a b c` and `trash a -Permanent b` working;
    # multiple sets combined with ValueFromRemainingArguments confuse the binder.
    begin {
        $mode = 'Recycle'
        $modes = @(foreach ($m in 'List', 'Restore', 'Purge', 'Empty') { if ($PSBoundParameters[$m]) { $m } })
        if ($modes.Count -gt 1) { throw "-$($modes -join ', -') cannot be used together." }
        if ($modes.Count -eq 1) { $mode = $modes[0] }
        if ($Permanent -and $mode -ne 'Recycle') { throw "-Permanent cannot be used with -$mode." }
        if ($mode -eq 'Empty' -and $Path) { throw '-Empty does not take any path.' }
        $patterns = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($mode -eq 'Recycle' -and $Path) {
            if ($_ -and $_.PSObject.TypeNames -contains 'TrashPs.Item') {
                throw 'Recycle Bin items cannot be recycled again; use -Restore or -Purge.'
            }
            if ($Permanent) {
                foreach ($target in $Path | ForEach-Object { Resolve-TargetPath $_ }) {
                    if ($PSCmdlet.ShouldProcess($target, 'Delete permanently')) {
                        Remove-Item -LiteralPath $target -Recurse -Force
                    }
                }
            }
            else {
                Move-ItemToTrash -Path $Path
            }
        }
        # Collect patterns from all pipeline input first, then act on them in end{}.
        if ($Path) { $patterns.AddRange([string[]]$Path) }
    }

    end {
        if ($mode -in 'Restore', 'Purge' -and $patterns.Count -eq 0) {
            throw "-$mode requires at least one Id or pattern."
        }
        switch ($mode) {
            'Recycle' { if ($patterns.Count -eq 0) { throw 'No path specified. Run "Get-Help trash" for usage.' } }
            'List' { Get-TrashItem -Filter $patterns }
            'Restore' { Restore-TrashItem -Filter $patterns }
            'Purge' { Remove-TrashItem -Filter $patterns -Force:$Force }
            'Empty' { Clear-Trash -Force:$Force }
        }
    }
}

Export-ModuleMember -Function Move-ItemToTrash, Get-TrashItem, Restore-TrashItem, Remove-TrashItem, Clear-Trash, trash
