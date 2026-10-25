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
    Short command for everyday Recycle Bin operations, with Unix-style options.

.DESCRIPTION
    trash [OPTION]... [--] [PATH|PATTERN]...

    By default every given path is moved to the Recycle Bin. Options select
    another operation, each forwarding to the matching command of this module:

        trash <path...>               Move-ItemToTrash
        trash --permanent <path...>   Remove-Item -Recurse -Force
        trash -l, --list [pattern...] Get-TrashItem
        trash --restore <pattern...>  Restore-TrashItem
        trash --purge <pattern...>    Remove-TrashItem
        trash --empty                 Clear-Trash

    Other options:

        -f, --force     Ignore nonexistent paths; do not ask with --purge and --empty
        -n, --dry-run   Show what would happen without doing it (same as -WhatIf)
        -v, --verbose   Explain what is being done
        -h, --help      Show this help
        -r, -R, -d      Accepted for rm compatibility; directories are always recycled whole
        '--'            Treat all following arguments as paths. PowerShell consumes a bare --
                        and splits unquoted -name.ext, so write trash '--' '-name.ext',
                        or simply trash ./-name.ext

    Short options can be combined (-rf), and long options may also be written
    PowerShell-style with a single dash (-List, -Restore, -Force, -WhatIf).
    Patterns are matched against the Id, name or original path of Recycle Bin items.

.EXAMPLE
    trash -rf build\ *.log

.EXAMPLE
    trash -l *.log | trash --restore
#>
function trash {
    # Arguments are parsed by hand instead of with param(), so that GNU-style
    # options (--list, -rf, --) work and unknown options are rejected.
    $longOptions = @{
        'list' = 'List'; 'restore' = 'Restore'; 'purge' = 'Purge'; 'empty' = 'Empty'
        'permanent' = 'Permanent'; 'force' = 'Force'; 'dry-run' = 'DryRun'; 'whatif' = 'DryRun'
        'verbose' = 'Verbose'; 'help' = 'Help'; 'recursive' = 'Recursive'
    }
    $shortOptions = [System.Collections.Generic.Dictionary[char, string]]::new()
    $shortOptions['l'] = 'List'; $shortOptions['e'] = 'Empty'; $shortOptions['f'] = 'Force'
    $shortOptions['n'] = 'DryRun'; $shortOptions['v'] = 'Verbose'; $shortOptions['h'] = 'Help'
    $shortOptions['r'] = 'Recursive'; $shortOptions['R'] = 'Recursive'; $shortOptions['d'] = 'Recursive'

    $flags = [System.Collections.Generic.HashSet[string]]::new()
    $operands = [System.Collections.Generic.List[string]]::new()
    $endOfOptions = $false

    foreach ($arg in @($input) + @($args | ForEach-Object { $_ })) {
        if ($null -eq $arg) { continue }
        if ($arg -isnot [string]) {
            if ($arg.PSObject.TypeNames -contains 'TrashPs.Item') { $flags.Add('TrashItemInput') | Out-Null; $operands.Add($arg.Id) }
            elseif ($arg -is [System.IO.FileSystemInfo]) { $operands.Add($arg.FullName) }
            else { $operands.Add("$arg") }
            continue
        }
        if ($endOfOptions -or $arg -eq '-' -or -not $arg.StartsWith('-')) {
            $operands.Add($arg)
            continue
        }
        if ($arg -eq '--') {
            $endOfOptions = $true
            continue
        }
        $name = $arg.TrimStart('-')
        if ($arg.StartsWith('--') -or $longOptions.ContainsKey($name)) {
            if (-not $longOptions.ContainsKey($name)) { throw "trash: unrecognized option '$arg'. Try 'trash --help'." }
            $flags.Add($longOptions[$name]) | Out-Null
            continue
        }
        foreach ($c in $name.ToCharArray()) {
            if (-not $shortOptions.ContainsKey($c)) { throw "trash: invalid option -- '$c'. Try 'trash --help'." }
            $flags.Add($shortOptions[$c]) | Out-Null
        }
    }

    # Piping an empty result (e.g. no matching Get-TrashItem) is not an error.
    if ($MyInvocation.ExpectingInput -and $operands.Count -eq 0 -and -not $flags.Contains('Help')) { return }

    if ($flags.Contains('Help')) {
        Get-Help trash -Full
        return
    }

    $modes = @('List', 'Restore', 'Purge', 'Empty' | Where-Object { $flags.Contains($_) })
    if ($modes.Count -gt 1) { throw "trash: --$(($modes -join ', --').ToLower()) cannot be used together." }
    $mode = if ($modes) { $modes[0] } else { 'Recycle' }
    $force = $flags.Contains('Force')
    if ($flags.Contains('Permanent') -and $mode -ne 'Recycle') { throw "trash: --permanent cannot be used with --$($mode.ToLower())." }
    if ($mode -eq 'Empty' -and $operands.Count) { throw 'trash: --empty does not take any argument.' }
    if ($mode -in 'Restore', 'Purge' -and $operands.Count -eq 0) { throw "trash: --$($mode.ToLower()) requires at least one Id or pattern." }

    $common = @{}
    if ($flags.Contains('DryRun')) { $common.WhatIf = $true }
    if ($flags.Contains('Verbose')) { $common.Verbose = $true }

    switch ($mode) {
        'Recycle' {
            if ($flags.Contains('TrashItemInput')) { throw 'trash: Recycle Bin items cannot be recycled again; use --restore or --purge.' }
            if ($operands.Count -eq 0) { throw "trash: missing operand. Try 'trash --help'." }
            $paths = @($operands | Where-Object {
                    # Like rm -f, silently skip paths that do not exist.
                    -not $force -or (Test-Path -LiteralPath $_) -or (Test-Path -Path $_)
                })
            if ($paths.Count -eq 0) { return }
            if ($flags.Contains('Permanent')) {
                foreach ($target in $paths | ForEach-Object { Resolve-TargetPath $_ }) {
                    Remove-Item -LiteralPath $target -Recurse -Force @common
                }
            }
            else {
                Move-ItemToTrash -Path $paths @common
            }
        }
        'List' { Get-TrashItem -Filter $operands }
        'Restore' { Restore-TrashItem -Filter $operands @common }
        'Purge' { Remove-TrashItem -Filter $operands -Force:$force @common }
        'Empty' { Clear-Trash -Force:$force @common }
    }
}

Export-ModuleMember -Function Move-ItemToTrash, Get-TrashItem, Restore-TrashItem, Remove-TrashItem, Clear-Trash, trash
