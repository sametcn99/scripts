#requires -Version 5.1

<#
.SYNOPSIS
    Scans Windows startup locations for broken or orphaned entries and
    optionally removes them after user confirmation.

.DESCRIPTION
    This script checks common Windows startup locations, including:

    - Current-user Run registry entries
    - Machine-wide Run registry entries
    - 32-bit machine-wide Run registry entries
    - Current-user Startup folder
    - Common Startup folder
    - Explorer StartupApproved registry entries

    Entries are classified as:

    - Valid:
        The referenced executable or startup target exists.

    - Broken:
        The referenced executable, script, or shortcut target no longer exists.

    - Unverified:
        The command could not be safely resolved. These entries are never
        removed automatically.

    Before removing anything, the script displays all detected broken entries
    and asks for explicit confirmation.

    Registry keys are exported to a backup directory before any registry
    modifications are made.

.NOTES
    Run PowerShell as Administrator if you want the script to be able to
    remove machine-wide startup entries under HKEY_LOCAL_MACHINE.

    The script intentionally uses conservative detection rules to reduce the
    risk of removing legitimate startup entries.

.EXAMPLE
    .\Clean-Startup.ps1

    Scans startup locations, displays broken entries, and asks whether they
    should be removed.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$RunLocations = @(
    @{
        Path  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        Scope = 'CurrentUser'
    },
    @{
        Path  = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
        Scope = 'LocalMachine'
    },
    @{
        Path  = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        Scope = 'LocalMachine32'
    }
)

$StartupApprovedLocations = @(
    @{
        Path       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        SourcePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        Type       = 'Run'
    },
    @{
        Path       = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        SourcePath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
        Type       = 'Run'
    },
    @{
        Path       = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        SourcePath = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        Type       = 'Run'
    },
    @{
        Path       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        SourcePath = [Environment]::GetFolderPath('Startup')
        Type       = 'StartupFolder'
    },
    @{
        Path       = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        SourcePath = [Environment]::GetFolderPath('CommonStartup')
        Type       = 'StartupFolder'
    }
)

$StartupFolders = @(
    @{
        Path  = [Environment]::GetFolderPath('Startup')
        Scope = 'CurrentUser'
    },
    @{
        Path  = [Environment]::GetFolderPath('CommonStartup')
        Scope = 'AllUsers'
    }
)

$IgnoredRegistryProperties = @(
    'PSPath',
    'PSParentPath',
    'PSChildName',
    'PSDrive',
    'PSProvider'
)

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-Section {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Get-RegistryValueNames {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    try {
        $item = Get-ItemProperty -LiteralPath $Path

        return @(
            $item.PSObject.Properties |
            Where-Object {
                $_.Name -notin $IgnoredRegistryProperties
            } |
            Select-Object -ExpandProperty Name
        )
    }
    catch {
        return @()
    }
}

function Resolve-StartupExecutable {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $null
    }

    $expandedCommand = [Environment]::ExpandEnvironmentVariables(
        $Command.Trim()
    )

    # Handle commands where the executable path is quoted.
    #
    # Example:
    # "C:\Program Files\Example\App.exe" --background
    if ($expandedCommand -match '^\s*"([^"]+)"') {
        return $matches[1]
    }

    # Handle unquoted paths ending in a known executable/script extension.
    #
    # Example:
    # C:\Tools\Example.exe --silent
    if (
        $expandedCommand -match
        '^\s*(.+?\.(?:exe|com|bat|cmd|ps1|vbs|js|wsf|msc))(?=\s|$)'
    ) {
        return $matches[1].Trim()
    }

    # Handle commands specified only by executable name.
    #
    # Example:
    # OneDrive.exe /background
    $firstToken = ($expandedCommand -split '\s+', 2)[0].Trim('"')

    if ($firstToken -notmatch '[\\/]') {
        try {
            $resolved = Get-Command $firstToken -ErrorAction Stop

            if ($resolved.Source) {
                return $resolved.Source
            }

            if ($resolved.Path) {
                return $resolved.Path
            }
        }
        catch {
            # Bare executable names that cannot be resolved should not be
            # classified as broken because Windows may resolve them using
            # mechanisms not represented by the current PowerShell session.
            return $null
        }
    }

    return $firstToken
}

function Test-StartupCommand {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Command
    )

    $resolvedPath = Resolve-StartupExecutable -Command $Command

    if (-not $resolvedPath) {
        return [PSCustomObject]@{
            Status = 'Unverified'
            Path   = $null
        }
    }

    $exists = Test-Path -LiteralPath $resolvedPath -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        Status = if ($exists) { 'Valid' } else { 'Broken' }
        Path   = $resolvedPath
    }
}

function Get-ShortcutTarget {
    param(
        [Parameter(Mandatory)]
        [string]$ShortcutPath
    )

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)

        $target = [Environment]::ExpandEnvironmentVariables(
            $shortcut.TargetPath
        )

        if ([string]::IsNullOrWhiteSpace($target)) {
            return [PSCustomObject]@{
                Status = 'Unverified'
                Path   = $null
            }
        }

        return [PSCustomObject]@{
            Status = if (Test-Path -LiteralPath $target) {
                'Valid'
            }
            else {
                'Broken'
            }

            Path   = $target
        }
    }
    catch {
        return [PSCustomObject]@{
            Status = 'Unverified'
            Path   = $null
        }
    }
}

function Backup-StartupRegistry {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    $backupDirectory = Join-Path `
        $env:USERPROFILE `
        "StartupCleanup-Backup-$timestamp"

    New-Item `
        -ItemType Directory `
        -Path $backupDirectory `
        -Force |
    Out-Null

    $registryKeys = @(
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved',
        'HKLM\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    )

    foreach ($registryKey in $registryKeys) {
        $safeFileName = ($registryKey -replace '[\\:]', '_') + '.reg'
        $destination = Join-Path $backupDirectory $safeFileName

        & reg.exe export $registryKey $destination /y 2>$null | Out-Null
    }

    return $backupDirectory
}

# ---------------------------------------------------------------------------
# Scan startup entries
# ---------------------------------------------------------------------------

Write-Section 'Windows Startup Health Check'

Write-Host 'Scanning startup configuration...'

$BrokenEntries = [System.Collections.Generic.List[object]]::new()
$UnverifiedEntries = [System.Collections.Generic.List[object]]::new()
$ValidEntries = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Scan Run registry keys
# ---------------------------------------------------------------------------

foreach ($location in $RunLocations) {
    if (-not (Test-Path -LiteralPath $location.Path)) {
        continue
    }

    try {
        $registryItem = Get-ItemProperty -LiteralPath $location.Path
    }
    catch {
        Write-Warning "Unable to read registry location: $($location.Path)"
        continue
    }

    foreach ($property in $registryItem.PSObject.Properties) {
        if ($property.Name -in $IgnoredRegistryProperties) {
            continue
        }

        $result = Test-StartupCommand -Command ([string]$property.Value)

        $entry = [PSCustomObject]@{
            Category = 'Registry Run'
            Name     = $property.Name
            Scope    = $location.Scope
            Target   = $result.Path
            Command  = [string]$property.Value
            Location = $location.Path
            Action   = 'RemoveRegistryValue'
        }

        switch ($result.Status) {
            'Broken' {
                $BrokenEntries.Add($entry)
            }

            'Valid' {
                $ValidEntries.Add($entry)
            }

            default {
                $UnverifiedEntries.Add($entry)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Scan Startup folders
# ---------------------------------------------------------------------------

foreach ($startupFolder in $StartupFolders) {
    if (-not (Test-Path -LiteralPath $startupFolder.Path)) {
        continue
    }

    foreach (
        $item in Get-ChildItem `
            -LiteralPath $startupFolder.Path `
            -Force `
            -ErrorAction SilentlyContinue
    ) {
        if ($item.PSIsContainer) {
            continue
        }

        if ($item.Extension -ieq '.lnk') {
            $result = Get-ShortcutTarget -ShortcutPath $item.FullName
        }
        else {
            $result = [PSCustomObject]@{
                Status = if (Test-Path -LiteralPath $item.FullName) {
                    'Valid'
                }
                else {
                    'Broken'
                }

                Path   = $item.FullName
            }
        }

        $entry = [PSCustomObject]@{
            Category = 'Startup Folder'
            Name     = $item.Name
            Scope    = $startupFolder.Scope
            Target   = $result.Path
            Command  = $item.FullName
            Location = $startupFolder.Path
            Action   = 'RemoveFile'
        }

        switch ($result.Status) {
            'Broken' {
                $BrokenEntries.Add($entry)
            }

            'Valid' {
                $ValidEntries.Add($entry)
            }

            default {
                $UnverifiedEntries.Add($entry)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Scan StartupApproved metadata
#
# StartupApproved contains Windows' enabled/disabled state for startup items.
# Entries may remain here after the original Run value or Startup shortcut has
# already been removed.
# ---------------------------------------------------------------------------

foreach ($location in $StartupApprovedLocations) {
    if (-not (Test-Path -LiteralPath $location.Path)) {
        continue
    }

    $approvedNames = Get-RegistryValueNames -Path $location.Path

    if ($location.Type -eq 'Run') {
        $sourceNames = Get-RegistryValueNames -Path $location.SourcePath
    }
    else {
        if (Test-Path -LiteralPath $location.SourcePath) {
            $sourceNames = @(
                Get-ChildItem `
                    -LiteralPath $location.SourcePath `
                    -Force `
                    -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Select-Object -ExpandProperty Name
            )
        }
        else {
            $sourceNames = @()
        }
    }

    foreach ($approvedName in $approvedNames) {
        if ($approvedName -in $sourceNames) {
            continue
        }

        $BrokenEntries.Add(
            [PSCustomObject]@{
                Category = 'StartupApproved'
                Name     = $approvedName
                Scope    = if ($location.Path.StartsWith('HKCU:')) {
                    'CurrentUser'
                }
                else {
                    'LocalMachine'
                }
                Target   = $null
                Command  = $null
                Location = $location.Path
                Action   = 'RemoveRegistryValue'
            }
        )
    }
}

# ---------------------------------------------------------------------------
# Display results
# ---------------------------------------------------------------------------

Write-Section 'Scan Results'

Write-Host "Valid entries      : $($ValidEntries.Count)" -ForegroundColor Green
Write-Host "Broken entries     : $($BrokenEntries.Count)" -ForegroundColor Yellow
Write-Host "Unverified entries : $($UnverifiedEntries.Count)" -ForegroundColor DarkYellow

if ($UnverifiedEntries.Count -gt 0) {
    Write-Host ''
    Write-Host 'The following entries could not be safely verified.' `
        -ForegroundColor DarkYellow

    Write-Host 'They will not be removed.' -ForegroundColor DarkGray

    $UnverifiedEntries |
    Select-Object Category, Name, Scope, Command |
    Format-Table -AutoSize -Wrap
}

if ($BrokenEntries.Count -eq 0) {
    Write-Host ''
    Write-Host 'No broken or orphaned startup entries were found.' `
        -ForegroundColor Green

    exit 0
}

Write-Section 'Broken Startup Entries'

$BrokenEntries |
Select-Object Category, Name, Scope, Target, Location |
Format-Table -AutoSize -Wrap

# ---------------------------------------------------------------------------
# Request confirmation
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host (
    "Found {0} broken or orphaned startup entr{1}." -f `
        $BrokenEntries.Count,
    $(if ($BrokenEntries.Count -eq 1) { 'y' } else { 'ies' })
) -ForegroundColor Yellow

$confirmation = Read-Host 'Remove these broken startup entries? [y/N]'

if ($confirmation -notmatch '^(?i:y|yes)$') {
    Write-Host ''
    Write-Host 'No changes were made.' -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------------------
# Backup registry configuration
# ---------------------------------------------------------------------------

Write-Section 'Creating Backup'

try {
    $backupDirectory = Backup-StartupRegistry

    Write-Host 'Registry backup created successfully:'
    Write-Host $backupDirectory -ForegroundColor Green
}
catch {
    Write-Error "Unable to create registry backup. Cleanup aborted."
    exit 1
}

# ---------------------------------------------------------------------------
# Remove broken entries
# ---------------------------------------------------------------------------

Write-Section 'Removing Broken Entries'

$removedCount = 0
$failedCount = 0

foreach ($entry in $BrokenEntries) {
    try {
        switch ($entry.Action) {
            'RemoveRegistryValue' {
                Remove-ItemProperty `
                    -LiteralPath $entry.Location `
                    -Name $entry.Name `
                    -Force `
                    -ErrorAction Stop

                Write-Host "[REMOVED] $($entry.Category): $($entry.Name)" `
                    -ForegroundColor Green
            }

            'RemoveFile' {
                Remove-Item `
                    -LiteralPath $entry.Command `
                    -Force `
                    -ErrorAction Stop

                Write-Host "[REMOVED] $($entry.Category): $($entry.Name)" `
                    -ForegroundColor Green
            }
        }

        $removedCount++
    }
    catch {
        $failedCount++

        Write-Warning (
            "Failed to remove '{0}' from '{1}': {2}" -f `
                $entry.Name,
            $entry.Location,
            $_.Exception.Message
        )
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Section 'Cleanup Summary'

Write-Host "Removed successfully : $removedCount" -ForegroundColor Green
Write-Host "Failed to remove      : $failedCount" `
    -ForegroundColor $(if ($failedCount -gt 0) { 'Yellow' } else { 'Green' })

Write-Host ''
Write-Host "Registry backup: $backupDirectory"

if (
    $failedCount -gt 0 -and
    -not (Test-IsAdministrator)
) {
    Write-Host ''
    Write-Host (
        'Some machine-wide entries may require an elevated PowerShell session.'
    ) -ForegroundColor Yellow

    Write-Host (
        'Run PowerShell as Administrator and execute the script again if needed.'
    ) -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Startup cleanup completed.' -ForegroundColor Green