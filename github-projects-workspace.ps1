#Requires -Version 7.0

<#
.SYNOPSIS
    Creates a structured local workspace and clones repositories from the
    currently authenticated GitHub account, including private repositories owned
    by that account.

.DESCRIPTION
    Workspace layout:

        projects/
        |-- AGENTS.md
        |-- backups/
        |-- clones/
        |-- local-projects/
        `-- github/
            |-- active/<github-user>/
            |-- archived/<github-user>/
            |-- forked/<source-owner>/{active|archived}/
            `-- organization/<organization>/{active|archived|forked}/

    Repository classification rules:

      1. Forks always go to github/forked/, grouped by upstream owner and
         archived state.
      2. Archived non-forks go to github/archived/.
      3. Organization repositories go to github/organization/<organization>/
         and keep the same active, archived, and forked grouping below it.
      4. Remaining repositories go to github/active/.

    If a projects directory already exists, the script requires explicit
    confirmation before deleting and recreating it.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$GitHubProfileUrl = 'https://github.com/sametcn99'

# -----------------------------------------------------------------------------
# Console helpers
# -----------------------------------------------------------------------------

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host '[INFO] ' -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host '[OK]   ' -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Skip {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host '[SKIP] ' -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Fail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host '[FAIL] ' -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Credit {
    Write-Host 'Credit      : sametcn99'
    Write-Host 'GitHub      : ' -NoNewline
    Write-Host $GitHubProfileUrl -ForegroundColor Blue
}

function Write-Intro {
    Write-Host ''
    Write-Host 'What this script does' -ForegroundColor White
    Write-Host '  - Connects to the authenticated GitHub account through GitHub CLI.'
    Write-Host '  - Discovers personal and organization repositories, including private ones.'
    Write-Host '  - Classifies repositories as active, archived, or forked and builds a clone plan.'
    Write-Host '  - Lets you review and select repositories with an interactive keyboard menu.'
    Write-Host ''
    Write-Host 'How it works' -ForegroundColor White
    Write-Host '  1. Checks Git, GitHub CLI, and authentication.'
    Write-Host '  2. Fetches repository metadata and prepares the proposed destinations.'
    Write-Host '  3. Shows warnings and waits for your final confirmation.'
    Write-Host '  4. Only after confirmation, creates the workspace and starts cloning.'
    Write-Host ''
    Write-Host 'Safety note: no workspace files or directories are changed before final confirmation.' -ForegroundColor Yellow
    Write-Credit
}

function Confirm-YesNo {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }

    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim().ToLowerInvariant()

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultYes
        }

        switch ($answer) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
            default {
                Write-Host 'Please enter y/yes or n/no.' -ForegroundColor Yellow
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Workspace selection
# -----------------------------------------------------------------------------

function Select-FolderWithDialog {
    param([Parameter(Mandatory)][string]$InitialDirectory)

    if ($env:OS -eq 'Windows_NT') {
        $dialog = $null

        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Select the parent directory where the projects folder will be created.'
            $dialog.ShowNewFolderButton = $false

            if (Test-Path -LiteralPath $InitialDirectory -PathType Container) {
                $dialog.SelectedPath = $InitialDirectory
            }

            $result = $dialog.ShowDialog()

            if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
                return [System.IO.Path]::GetFullPath($dialog.SelectedPath)
            }

            return $null
        }
        catch {
            Write-Host 'Could not open the native folder picker.' -ForegroundColor Yellow
            Write-Host 'Falling back to manual path entry.' -ForegroundColor DarkGray
        }
        finally {
            if ($null -ne $dialog) {
                $dialog.Dispose()
            }
        }
    }

    while ($true) {
        $value = Read-Host 'Enter a directory path, or press Enter to cancel'

        if ([string]::IsNullOrWhiteSpace($value)) {
            return $null
        }

        $value = $value.Trim().Trim('"')

        if (Test-Path -LiteralPath $value -PathType Container) {
            return [System.IO.Path]::GetFullPath($value)
        }

        Write-Host "Directory does not exist: $value" -ForegroundColor Yellow
    }
}

function Select-WorkspaceParent {
    $currentDirectory = [System.IO.Path]::GetFullPath((Get-Location).Path)

    Write-Section 'Workspace Location'
    Write-Host 'Current directory:'
    Write-Host $currentDirectory -ForegroundColor White
    Write-Host ''

    if (Confirm-YesNo -Prompt 'Use this directory as the workspace parent?' -DefaultYes $true) {
        return $currentDirectory
    }

    while ($true) {
        Write-Info 'Opening directory selector...'
        $selected = Select-FolderWithDialog -InitialDirectory $currentDirectory

        if ([string]::IsNullOrWhiteSpace($selected)) {
            return $null
        }

        Write-Host ''
        Write-Host 'Selected directory:'
        Write-Host $selected -ForegroundColor White
        Write-Host ''

        if (Confirm-YesNo -Prompt 'Use this directory as the workspace parent?' -DefaultYes $true) {
            return $selected
        }
    }
}

# -----------------------------------------------------------------------------
# Dependency and GitHub checks
# -----------------------------------------------------------------------------

function Test-Dependencies {
    Write-Section 'Dependency Checks'

    foreach ($commandName in @('git', 'gh')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue

        if ($null -eq $command) {
            throw "$commandName is not installed or is not available in PATH."
        }

        Write-Ok "$commandName found: $($command.Source)"
    }
}

function Test-GitHubAuthentication {
    Write-Info 'Checking GitHub CLI authentication...'

    $output = & gh auth status 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "GitHub CLI is not authenticated. Run 'gh auth login' first.$([Environment]::NewLine)$details"
    }

    Write-Ok 'GitHub CLI authentication is valid.'
}

function Get-GitHubUsername {
    Write-Info 'Detecting the authenticated GitHub username...'

    $output = & gh api user --jq '.login' 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "Could not determine the GitHub username.$([Environment]::NewLine)$details"
    }

    $username = (($output | Select-Object -First 1).ToString()).Trim()

    if ([string]::IsNullOrWhiteSpace($username)) {
        throw 'GitHub CLI returned an empty username.'
    }

    Write-Ok "Authenticated as: $username"
    return $username
}

# -----------------------------------------------------------------------------
# Workspace initialization and destructive-operation safety
# -----------------------------------------------------------------------------

function Assert-SafeProjectsPath {
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][string]$ProjectsRoot
    )

    $baseFull = [System.IO.Path]::GetFullPath($BaseDirectory).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    $projectsFull = [System.IO.Path]::GetFullPath($ProjectsRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    $expectedFull = [System.IO.Path]::GetFullPath(
        (Join-Path $baseFull 'projects')
    ).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    if (-not [string]::Equals($projectsFull, $expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe deletion target. Expected '$expectedFull' but got '$projectsFull'."
    }

    $leafName = Split-Path -Leaf $projectsFull
    if (-not [string]::Equals($leafName, 'projects', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing deletion because the target directory is not named projects.'
    }

    if ([string]::Equals($projectsFull, $baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing deletion because the projects directory resolves to the workspace parent.'
    }

    $filesystemRoot = [System.IO.Path]::GetPathRoot($projectsFull).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    if ([string]::Equals($projectsFull, $filesystemRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing deletion because the target resolves to a filesystem root.'
    }

    if (Test-Path -LiteralPath $projectsFull -PathType Container) {
        $item = Get-Item -LiteralPath $projectsFull -Force
        $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

        if ($isReparsePoint) {
            throw 'Refusing to delete projects because it is a symbolic link, junction, or another reparse point.'
        }
    }
}

function Initialize-ProjectsWorkspace {
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [Parameter(Mandatory)][string]$GitHubRoot,
        [switch]$Confirmed
    )

    Write-Section 'Projects Workspace'
    Write-Host "Workspace parent : $BaseDirectory"
    Write-Host "Projects root    : $ProjectsRoot"
    Write-Host ''

    if (Test-Path -LiteralPath $ProjectsRoot -PathType Leaf) {
        throw "A file named 'projects' already exists at: $ProjectsRoot"
    }

    if (Test-Path -LiteralPath $ProjectsRoot -PathType Container) {
        Write-Host 'The projects directory already exists.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'WARNING: continuing will permanently delete:' -ForegroundColor Red
        Write-Host "    $ProjectsRoot" -ForegroundColor White
        Write-Host ''
        Write-Host 'This can include local-only projects, uncommitted changes, and files that exist nowhere else.' -ForegroundColor Yellow
        Write-Host ''

        if (-not $Confirmed -and -not (Confirm-YesNo -Prompt 'Delete and recreate the projects directory?' -DefaultYes $false)) {
            Write-Info 'Operation cancelled. The existing projects directory was not changed.'
            return $false
        }

        Assert-SafeProjectsPath -BaseDirectory $BaseDirectory -ProjectsRoot $ProjectsRoot

        Write-Info 'Deleting the existing projects directory...'
        Remove-Item -LiteralPath $ProjectsRoot -Recurse -Force
        Write-Ok 'Existing projects directory deleted.'
    }

    foreach ($path in @(
            $ProjectsRoot,
            (Join-Path $ProjectsRoot 'backups'),
            (Join-Path $ProjectsRoot 'clones'),
            (Join-Path $ProjectsRoot 'local-projects'),
            $GitHubRoot,
            (Join-Path $GitHubRoot 'active'),
            (Join-Path $GitHubRoot 'archived'),
            (Join-Path $GitHubRoot 'forked')
        )) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    Write-Ok 'Workspace directory structure created.'
    return $true
}

function Show-WorkspaceChangeWarning {
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot
    )

    Write-Host ''
    Write-Host 'WARNING: No workspace changes have been made yet.' -ForegroundColor Yellow
    Write-Host 'After the next confirmation, the script will:'

    if (Test-Path -LiteralPath $ProjectsRoot -PathType Container) {
        Write-Host "  - Permanently delete and recreate: $ProjectsRoot" -ForegroundColor Red
    }
    else {
        Write-Host "  - Create the workspace directory: $ProjectsRoot"
    }

    Write-Host '  - Write the workspace AGENTS.md file'
    Write-Host '  - Create clone destination directories and clone the selected repositories'
}

# -----------------------------------------------------------------------------
# AGENTS.md
# -----------------------------------------------------------------------------

function New-AgentsFile {
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [Parameter(Mandatory)][string]$Username
    )

    $agentsPath = Join-Path $ProjectsRoot 'AGENTS.md'

    $template = @'
# Projects Workspace

This directory is a managed local workspace for software projects associated
with the authenticated GitHub account `{{USERNAME}}`.

## Scope and Precedence

This document defines workspace-level guidance. A repository's own
`AGENTS.md`, `README`, contribution guide, or project configuration may define
more specific rules; follow those rules when working inside that repository.

Do not assume that a workspace-level convention applies to the implementation,
build, or release process of an individual project.

## Directory Layout

```text
projects/
|-- AGENTS.md
|-- backups/
|-- clones/
|-- local-projects/
`-- github/
    |-- active/<github-user>/<repository>/
    |-- archived/<github-user>/<repository>/
    |-- forked/<source-owner>/{active|archived}/<repository>/
    `-- organization/<organization>/{active|archived|forked}/<repository>/
```

The `github/` tree is managed by the GitHub workspace script. The
`local-projects/` directory is a user-managed area for projects that are not
necessarily hosted on GitHub. The script creates the directory but does not
discover or populate it.

The `clones/` directory is a user-managed area for repositories cloned
manually. The script creates the directory but does not discover or populate
it.

The `backups/` directory is a user-managed area for workspace backups. The
script creates the directory but does not create or manage backup files.

## Repository Classification

Each discovered repository is placed in exactly one category using this
priority order:

1. Forked personal repositories are placed in `github/forked/`, grouped by
   upstream owner and then by `active/` or `archived/` status.
2. Archived non-fork personal repositories are placed in `github/archived/`.
3. Organization repositories are placed in
   `github/organization/<organization>/`, grouped by `active/`, `archived/`,
   or `forked/`.
4. All remaining personal repositories are placed in `github/active/`.

Category definitions:

- `active/` contains non-archived repositories that are not forks.
- `archived/` contains archived repositories that are not forks.
- `forked/<source-owner>/active/` contains non-archived forks grouped by their
  upstream source owner.
- `forked/<source-owner>/archived/` contains archived forks grouped by their
  upstream source owner.
- `organization/<organization>/active/` contains active repositories owned by
  an organization.
- `organization/<organization>/archived/` contains archived repositories owned
  by an organization.
- `organization/<organization>/forked/<source-owner>/{active|archived}/`
  contains organization forks grouped by upstream owner.

If an upstream owner cannot be resolved, the fork is placed in
`github/forked/unknown-upstream/{active|archived}/`.

Repository classification is metadata-driven. Do not manually move a
repository between categories unless the workspace organization is being
intentionally changed.

## Private Repositories

Repository discovery uses the authenticated GitHub CLI account and includes
private repositories owned by that account. Private repositories must be
treated as confidential source code. Do not publish, copy, or share their
contents, credentials, tokens, or private URLs outside an authorized context.

The workspace does not store GitHub credentials. Authentication is provided by
the local GitHub CLI configuration and must not be committed to this directory.

## Working in a Repository

- Read the repository's local instructions before making changes.
- Check the repository status before editing, and preserve unrelated local work.
- Use the repository's documented tooling and test commands.
- Keep changes isolated to the intended repository and task.
- Review the final diff and test results before reporting completion.
- Treat nested `AGENTS.md` files as more specific guidance for their directory.

## Workspace Lifecycle

The workspace script uses Git and GitHub CLI (`gh`) to discover and clone
repositories. It may recreate the entire `projects/` directory, but only after
explicit confirmation.

Before approving a recreation:

- Back up local-only projects and important files.
- Check for uncommitted changes in existing repositories.
- Confirm that no data exists only inside the current `projects/` directory.

The script creates this file as part of workspace initialization. Manual edits
may be overwritten the next time the workspace is recreated.

## Safety Rules

- Do not run destructive commands without verifying their target and scope.
- Do not commit secrets, credentials, tokens, or private configuration.
- Do not assume that a cloned repository is safe to modify without checking its
  local instructions.
- Preserve the `active`, `archived`, and nested `forked/<source-owner>/active`
  and `forked/<source-owner>/archived` directory structure.
'@

    $content = $template.Replace('{{USERNAME}}', $Username)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($agentsPath, $content.Trim() + [Environment]::NewLine, $utf8NoBom)

    Write-Ok "Created: $agentsPath"
}

# -----------------------------------------------------------------------------
# Repository selection and discovery
# -----------------------------------------------------------------------------

function Select-RepositoryCategories {
    param([Parameter(Mandatory)][object[]]$Organizations)

    Write-Section 'Repository Categories'

    while ($true) {
        Write-Host 'Select the repository sources to include:'
        Write-Host ''
        Write-Host '  [1] Personal - Active'
        Write-Host '  [2] Personal - Archived'
        Write-Host '  [3] Personal - Forked'
        $organizationLabel = 'Organizations'
        if ($Organizations.Count -gt 0) {
            $organizationLabel += " (all: $($Organizations.Login -join ', '))"
        }
        else {
            $organizationLabel += ' (none available)'
        }
        Write-Host "  [4] $organizationLabel"
        Write-Host '  [5] All available sources'
        Write-Host ''
        Write-Host 'You can select multiple options, for example: 1,3,4'
        Write-Host ''

        $selection = (Read-Host 'Selection').Trim()

        if ([string]::IsNullOrWhiteSpace($selection)) {
            Write-Host 'Select at least one category.' -ForegroundColor Yellow
            continue
        }

        $tokens = @($selection -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $selected = [System.Collections.Generic.List[string]]::new()
        $includeOrganizations = $false
        $invalid = [System.Collections.Generic.List[string]]::new()

        foreach ($token in $tokens) {
            switch ($token.Trim().ToLowerInvariant()) {
                '1' { $selected.Add('Active'); break }
                'active' { $selected.Add('Active'); break }
                '2' { $selected.Add('Archived'); break }
                'archived' { $selected.Add('Archived'); break }
                '3' { $selected.Add('Forked'); break }
                'forked' { $selected.Add('Forked'); break }
                '4' { $includeOrganizations = $true; break }
                'organizations' { $includeOrganizations = $true; break }
                'organization' { $includeOrganizations = $true; break }
                '5' {
                    $selected = [System.Collections.Generic.List[string]]::new()
                    $selected.AddRange([string[]]@('Active', 'Archived', 'Forked'))
                    $includeOrganizations = $true
                    break
                }
                'all' {
                    $selected = [System.Collections.Generic.List[string]]::new()
                    $selected.AddRange([string[]]@('Active', 'Archived', 'Forked'))
                    $includeOrganizations = $true
                    break
                }
                default { $invalid.Add($token) }
            }
        }

        if ($invalid.Count -gt 0) {
            Write-Host "Invalid selection: $($invalid -join ', ')" -ForegroundColor Yellow
            continue
        }

        $unique = @($selected | Select-Object -Unique)

        if ($includeOrganizations -and $Organizations.Count -eq 0) {
            Write-Host 'No organizations are available for this account.' -ForegroundColor Yellow
            continue
        }

        if ($unique.Count -gt 0 -or $includeOrganizations) {
            return [PSCustomObject]@{
                Categories           = $unique
                IncludeOrganizations = $includeOrganizations
                Organizations        = if ($includeOrganizations) { @($Organizations) } else { @() }
            }
        }

        Write-Host 'Select at least one category or organization.' -ForegroundColor Yellow
    }
}

function Get-GitHubOrganizations {
    Write-Info 'Fetching organizations available to the authenticated account...'

    $output = & gh api --paginate --slurp -X GET 'user/orgs?per_page=100' 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "Failed to retrieve organizations.$([Environment]::NewLine)$details"
    }

    $json = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($json)) {
        return @()
    }

    try {
        $pages = @(ConvertFrom-Json -InputObject $json)
    }
    catch {
        throw "GitHub CLI returned invalid organization JSON: $($_.Exception.Message)"
    }

    $organizations = [System.Collections.Generic.List[object]]::new()
    foreach ($page in $pages) {
        foreach ($organization in @($page)) {
            $organizations.Add([PSCustomObject]@{
                    Login = $organization.login
                })
        }
    }

    Write-Ok "Found $($organizations.Count) organizations."
    return @($organizations | Sort-Object Login)
}

function Get-GitHubRepositories {
    param(
        [Parameter(Mandatory)][string]$Username,
        [object[]]$Organizations = @()
    )

    Write-Section 'Repository Discovery'
    Write-Info "Fetching public and private repositories owned by $Username..."

    # Use the authenticated user's repository endpoint so private repositories
    # are included. The user-specific /users/{username}/repos endpoint only
    # exposes public repositories in this context.
    $output = & gh api --paginate --slurp -X GET 'user/repos?visibility=all&affiliation=owner&per_page=100' 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "Failed to retrieve repositories.$([Environment]::NewLine)$details"
    }

    $json = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    $repositories = [System.Collections.Generic.List[object]]::new()

    if (-not [string]::IsNullOrWhiteSpace($json)) {
        try {
            $pages = @(ConvertFrom-Json -InputObject $json)
        }
        catch {
            throw "GitHub CLI returned invalid repository JSON: $($_.Exception.Message)"
        }

        foreach ($page in $pages) {
            foreach ($repository in @($page)) {
                $repositories.Add([PSCustomObject]@{
                        name          = $repository.name
                        nameWithOwner = $repository.full_name
                        isArchived    = [bool]$repository.archived
                        isFork        = [bool]$repository.fork
                        visibility    = $repository.visibility
                        url           = $repository.html_url
                        Scope         = 'Personal'
                        Organization  = $null
                    })
            }
        }
    }

    foreach ($organization in $Organizations) {
        Write-Info "Fetching repositories for organization $($organization.Login)..."
        $organizationOutput = & gh api --paginate --slurp -X GET "orgs/$($organization.Login)/repos?type=all&per_page=100" 2>&1
        $organizationExitCode = $LASTEXITCODE

        if ($organizationExitCode -ne 0) {
            $details = ($organizationOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            throw "Failed to retrieve repositories for organization $($organization.Login).$([Environment]::NewLine)$details"
        }

        $organizationJson = ($organizationOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($organizationJson)) {
            continue
        }

        try {
            $organizationPages = @(ConvertFrom-Json -InputObject $organizationJson)
        }
        catch {
            throw "GitHub CLI returned invalid repository JSON for organization $($organization.Login): $($_.Exception.Message)"
        }

        foreach ($page in $organizationPages) {
            foreach ($repository in @($page)) {
                $repositories.Add([PSCustomObject]@{
                        name          = $repository.name
                        nameWithOwner = $repository.full_name
                        isArchived    = [bool]$repository.archived
                        isFork        = [bool]$repository.fork
                        visibility    = $repository.visibility
                        url           = $repository.html_url
                        Scope         = 'Organization'
                        Organization  = $organization.Login
                    })
            }
        }
    }

    Write-Ok "Found $($repositories.Count) repositories across the selected sources."
    return @($repositories)
}

function Get-RepositoryCategory {
    param([Parameter(Mandatory)][object]$Repository)

    if ([bool]$Repository.isFork) {
        return 'Forked'
    }

    if ([bool]$Repository.isArchived) {
        return 'Archived'
    }

    return 'Active'
}

function Get-ForkSourceOwner {
    param([Parameter(Mandatory)][string]$NameWithOwner)

    $output = & gh api "repos/$NameWithOwner" --jq '.source.owner.login // .parent.owner.login // empty' 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0 -and $null -ne $output) {
        $owner = (($output | Select-Object -First 1).ToString()).Trim()

        if (-not [string]::IsNullOrWhiteSpace($owner)) {
            return $owner
        }
    }

    Write-Host "[WARN] Could not resolve source owner for $NameWithOwner; using unknown-upstream." -ForegroundColor Yellow
    return 'unknown-upstream'
}

function ConvertTo-SafePathSegment {
    param([Parameter(Mandatory)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return '_unknown'
    }

    $result = $Value

    foreach ($invalidCharacter in [System.IO.Path]::GetInvalidFileNameChars()) {
        $result = $result.Replace($invalidCharacter.ToString(), '_')
    }

    $result = $result.TrimEnd('.', ' ')

    if ([string]::IsNullOrWhiteSpace($result)) {
        return '_unknown'
    }

    if ($env:OS -eq 'Windows_NT' -and $result -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
        $result = "_$result"
    }

    return $result
}

function New-ClonePlan {
    param(
        [Parameter(Mandatory)][object[]]$Repositories,
        [string[]]$Categories = @(),
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$GitHubRoot,
        [bool]$IncludeOrganizations = $false
    )

    Write-Info 'Classifying repositories and resolving fork source owners...'

    $selectedRepositories = @(
        $Repositories | Where-Object {
            $category = Get-RepositoryCategory -Repository $_
            if ($_.Scope -eq 'Organization') {
                $IncludeOrganizations
            }
            else {
                $Categories -contains $category
            }
        }
    )

    $plan = [System.Collections.Generic.List[object]]::new()
    $total = $selectedRepositories.Count
    $index = 0

    foreach ($repository in $selectedRepositories) {
        $index++
        $category = Get-RepositoryCategory -Repository $repository

        $percent = 100
        if ($total -gt 0) {
            $percent = [math]::Floor(($index / $total) * 100)
        }

        Write-Progress -Activity 'Building clone plan' -Status "$index / $total - $($repository.nameWithOwner)" -PercentComplete $percent

        if ($category -eq 'Forked') {
            $ownerDirectory = Get-ForkSourceOwner -NameWithOwner $repository.nameWithOwner
        }
        else {
            $ownerDirectory = $Username
        }

        $safeOwner = ConvertTo-SafePathSegment -Value $ownerDirectory
        $safeRepositoryName = ConvertTo-SafePathSegment -Value $repository.name
        $repositoryState = if ([bool]$repository.isArchived) { 'archived' } else { 'active' }
        $scope = if ($repository.Scope -eq 'Organization') { 'Organization' } else { 'Personal' }
        $organizationName = if ($scope -eq 'Organization') { [string]$repository.Organization } else { $null }

        if ($scope -eq 'Organization') {
            $safeOrganization = ConvertTo-SafePathSegment -Value $organizationName
            $organizationRoot = Join-Path (Join-Path $GitHubRoot 'organization') $safeOrganization
            $categoryRoot = Join-Path $organizationRoot $category.ToLowerInvariant()

            if ($category -eq 'Forked') {
                $ownerRoot = Join-Path (Join-Path $categoryRoot $safeOwner) $repositoryState
                $destination = Join-Path $ownerRoot $safeRepositoryName
            }
            else {
                $destination = Join-Path $categoryRoot $safeRepositoryName
            }
        }
        else {
            $categoryRoot = Join-Path $GitHubRoot $category.ToLowerInvariant()

            if ($category -eq 'Forked') {
                $ownerRoot = Join-Path (Join-Path $categoryRoot $safeOwner) $repositoryState
                $destination = Join-Path $ownerRoot $safeRepositoryName
            }
            else {
                $destination = Join-Path (Join-Path $categoryRoot $safeOwner) $safeRepositoryName
            }
        }

        $plan.Add([PSCustomObject]@{
                Name          = $repository.name
                NameWithOwner = $repository.nameWithOwner
                Category      = $category
                Status        = $repositoryState
                Scope         = $scope
                Organization  = $organizationName
                Visibility    = $repository.visibility
                SourceOwner   = $ownerDirectory
                Destination   = $destination
                Url           = $repository.url
            })
    }

    Write-Progress -Activity 'Building clone plan' -Completed
    return @($plan)
}

# -----------------------------------------------------------------------------
# Clone plan and execution
# -----------------------------------------------------------------------------

function Show-ClonePlan {
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [string[]]$Categories = @(),
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [object[]]$Organizations = @()
    )

    Write-Section 'Clone Plan'
    Write-Host "GitHub account : $Username"
    Write-Host "Projects root  : $ProjectsRoot"
    $sources = @($Categories)
    if ($Organizations.Count -gt 0) {
        $sources += "Organizations ($($Organizations.Login -join ', '))"
    }
    Write-Host "Sources        : $($sources -join ', ')"
    Write-Host ''

    foreach ($category in @('Active', 'Archived', 'Forked')) {
        if ($Categories -contains $category) {
            $categoryItems = @($Plan | Where-Object { $_.Category -eq $category })
            $publicCount = @($categoryItems | Where-Object { $_.Visibility -eq 'public' }).Count
            $privateCount = @($categoryItems | Where-Object { $_.Visibility -eq 'private' }).Count
            $internalCount = @($categoryItems | Where-Object { $_.Visibility -eq 'internal' }).Count
            $visibilitySummary = "Public: $publicCount, Private: $privateCount"

            if ($internalCount -gt 0) {
                $visibilitySummary += ", Internal: $internalCount"
            }

            Write-Host ('{0,-10}: {1} ({2})' -f $category, $categoryItems.Count, $visibilitySummary)
        }
    }

    $totalPublicCount = @($Plan | Where-Object { $_.Visibility -eq 'public' }).Count
    $totalPrivateCount = @($Plan | Where-Object { $_.Visibility -eq 'private' }).Count
    $totalInternalCount = @($Plan | Where-Object { $_.Visibility -eq 'internal' }).Count
    $totalVisibilitySummary = "Public: $totalPublicCount, Private: $totalPrivateCount"

    if ($totalInternalCount -gt 0) {
        $totalVisibilitySummary += ", Internal: $totalInternalCount"
    }

    Write-Host ('{0,-10}: {1} ({2})' -f 'Total', $Plan.Count, $totalVisibilitySummary)

    if ($Plan.Count -eq 0) {
        return
    }

    Write-Host ''
    foreach ($item in @($Plan | Sort-Object Category, SourceOwner, Name)) {
        $displayCategory = if ($item.Scope -eq 'Organization') {
            "Organization/$($item.Organization)/$($item.Category)"
        }
        else {
            "Personal/$($item.Category)"
        }

        if ($item.Category -eq 'Forked') {
            $displayCategory += "/$($item.Status)"
        }

        Write-Host ('[{0}] {1} ({2})' -f $displayCategory, $item.NameWithOwner, $item.Visibility) -ForegroundColor Cyan
        Write-Host "    -> $($item.Destination)"
    }
}

function Get-PlanGroupLabel {
    param([Parameter(Mandatory)][object]$Item)

    $label = if ($Item.Scope -eq 'Organization') {
        "Organization/$($Item.Organization)/$($Item.Category)"
    }
    else {
        "Personal/$($Item.Category)"
    }

    if ($Item.Category -eq 'Forked') {
        $label += "/$($Item.Status)"
    }

    return $label
}

function Select-ClonePlanItems {
    param([Parameter(Mandatory)][object[]]$Plan)

    Write-Section 'Interactive Clone Plan Selection'
    Write-Host 'Use Up/Down to move, Space to toggle, Enter to continue, and Esc to cancel.'
    Write-Host 'Group rows toggle all repositories in that group.'

    $groups = [System.Collections.Generic.List[object]]::new()
    $groupByLabel = @{}

    foreach ($item in @($Plan | Sort-Object Scope, Organization, Category, Status, Name)) {
        $label = Get-PlanGroupLabel -Item $item

        if (-not $groupByLabel.ContainsKey($label)) {
            $groupNumber = $groups.Count + 1
            $group = [PSCustomObject]@{
                Code  = "G$groupNumber"
                Label = $label
                Items = [System.Collections.Generic.List[object]]::new()
            }
            $groups.Add($group)
            $groupByLabel[$label] = $group
        }

        $groupByLabel[$label].Items.Add($item)
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    $repositoryNumber = 0

    foreach ($group in $groups) {
        $entries.Add([PSCustomObject]@{
                Type  = 'Group'
                Code  = $group.Code
                Label = $group.Label
                Group = $group
                Item  = $null
            })

        foreach ($item in $group.Items) {
            $repositoryNumber++
            $code = "R$repositoryNumber"
            $entries.Add([PSCustomObject]@{
                    Type  = 'Repository'
                    Code  = $code
                    Label = $null
                    Group = $group
                    Item  = $item
                })
        }
    }

    if ($entries.Count -eq 0) {
        return @()
    }

    $selectedKeys = @{}
    $cursor = 0
    $cancelled = $false

    $getItemKey = {
        param([Parameter(Mandatory)][object]$Item)
        return "$($Item.NameWithOwner)|$($Item.Destination)"
    }

    $getGroupState = {
        param([Parameter(Mandatory)][object]$Group)

        $selectedCount = 0
        foreach ($item in $Group.Items) {
            if ($selectedKeys.ContainsKey((& $getItemKey -Item $item))) {
                $selectedCount++
            }
        }

        if ($selectedCount -eq 0) {
            return ' '
        }

        if ($selectedCount -eq $Group.Items.Count) {
            return 'x'
        }

        return '-'
    }

    $render = {
        [Console]::Clear()
        Write-Host 'Interactive Clone Plan Selection' -ForegroundColor Cyan
        Write-Host 'Up/Down: move   Space: toggle   A: all   N: none   Enter: continue   Esc: cancel'
        Write-Host "Showing $($cursor + 1) of $($entries.Count) entries"

        $windowHeight = [int]$Host.UI.RawUI.WindowSize.Height
        $windowWidth = [int]$Host.UI.RawUI.WindowSize.Width
        $visibleCount = [Math]::Max(1, $windowHeight - 4)
        $maxStart = [Math]::Max(0, $entries.Count - $visibleCount)
        $start = [Math]::Min(
            $maxStart,
            [Math]::Max(0, $cursor - [int]($visibleCount / 2))
        )
        $end = [Math]::Min($entries.Count, $start + $visibleCount)
        $lineWidth = [Math]::Max(20, $windowWidth - 1)

        for ($index = $start; $index -lt $end; $index++) {
            $entry = $entries[$index]
            $pointer = if ($index -eq $cursor) { '>' } else { ' ' }

            if ($entry.Type -eq 'Group') {
                $state = & $getGroupState -Group $entry.Group
                $line = "$pointer [$state] $($entry.Code) $($entry.Label) ($($entry.Group.Items.Count) repositories)"
                if ($line.Length -gt $lineWidth) {
                    $line = $line.Substring(0, $lineWidth - 3) + '...'
                }
                Write-Host $line -ForegroundColor Cyan
                continue
            }

            $key = & $getItemKey -Item $entry.Item
            $state = if ($selectedKeys.ContainsKey($key)) { 'x' } else { ' ' }
            $line = "$pointer [$state] $($entry.Code) $($entry.Item.NameWithOwner) ($($entry.Item.Visibility)) -> $($entry.Item.Destination)"
            if ($line.Length -gt $lineWidth) {
                $line = $line.Substring(0, $lineWidth - 3) + '...'
            }
            Write-Host $line
        }
    }

    $cursorWasVisible = [Console]::CursorVisible
    try {
        [Console]::CursorVisible = $false
        & $render

        while ($true) {
            $keyInfo = $Host.UI.RawUI.ReadKey(
                [System.Management.Automation.Host.ReadKeyOptions]::NoEcho -bor
                [System.Management.Automation.Host.ReadKeyOptions]::IncludeKeyDown
            )
            $virtualKeyCode = [int]$keyInfo.VirtualKeyCode

            switch ($virtualKeyCode) {
                38 {
                    $cursor = if ($cursor -eq 0) { $entries.Count - 1 } else { $cursor - 1 }
                }
                40 {
                    $cursor = if ($cursor -eq ($entries.Count - 1)) { 0 } else { $cursor + 1 }
                }
                32 {
                    $entry = $entries[$cursor]

                    if ($entry.Type -eq 'Group') {
                        $allSelected = (& $getGroupState -Group $entry.Group) -eq 'x'
                        foreach ($item in $entry.Group.Items) {
                            $key = & $getItemKey -Item $item
                            if ($allSelected) {
                                $selectedKeys.Remove($key)
                            }
                            else {
                                $selectedKeys[$key] = $true
                            }
                        }
                    }
                    else {
                        $key = & $getItemKey -Item $entry.Item
                        if ($selectedKeys.ContainsKey($key)) {
                            $selectedKeys.Remove($key)
                        }
                        else {
                            $selectedKeys[$key] = $true
                        }
                    }
                }
                65 {
                    foreach ($item in $Plan) {
                        $selectedKeys[(& $getItemKey -Item $item)] = $true
                    }
                }
                78 {
                    $selectedKeys.Clear()
                }
                13 {
                    if ($selectedKeys.Count -gt 0) {
                        break
                    }
                }
                27 {
                    $cancelled = $true
                    break
                }
            }

            if ($virtualKeyCode -in @(13, 27) -and ($selectedKeys.Count -gt 0 -or $cancelled)) {
                break
            }

            & $render
        }
    }
    finally {
        [Console]::CursorVisible = $cursorWasVisible
        [Console]::Clear()
    }

    if ($cancelled) {
        return @()
    }

    return @(
        $Plan | Where-Object {
            $selectedKeys.ContainsKey((& $getItemKey -Item $_))
        }
    )
}

function Invoke-ClonePlan {
    param([Parameter(Mandatory)][object[]]$Plan)

    Write-Section 'Cloning Repositories'

    $cloned = 0
    $skipped = 0
    $failed = 0
    $failures = [System.Collections.Generic.List[object]]::new()
    $total = $Plan.Count

    for ($i = 0; $i -lt $total; $i++) {
        $item = $Plan[$i]
        $number = $i + 1
        $percent = [math]::Floor(($number / $total) * 100)

        Write-Progress -Activity 'Cloning GitHub repositories' -Status "$number / $total - $($item.NameWithOwner)" -PercentComplete $percent

        Write-Host ''
        Write-Host "[$number/$total] $($item.NameWithOwner)" -ForegroundColor Cyan
        Write-Host "    Category    : $($item.Category)"
        Write-Host "    Destination : $($item.Destination)"

        if (Test-Path -LiteralPath $item.Destination) {
            $gitMetadata = Join-Path $item.Destination '.git'

            if (Test-Path -LiteralPath $gitMetadata) {
                Write-Skip "$($item.NameWithOwner) already exists as a Git repository."
                $skipped++
                continue
            }

            Write-Fail "$($item.NameWithOwner): destination exists but is not a Git repository."
            $failed++
            $failures.Add([PSCustomObject]@{
                    Repository = $item.NameWithOwner
                    Reason     = 'Destination exists but is not a Git repository.'
                })
            continue
        }

        $parentDirectory = Split-Path -Parent $item.Destination
        New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null

        $cloneOutput = & gh repo clone $item.NameWithOwner $item.Destination 2>&1
        $cloneExitCode = $LASTEXITCODE

        if ($cloneExitCode -eq 0) {
            Write-Ok "$($item.NameWithOwner) cloned successfully."
            $cloned++
        }
        else {
            $details = ($cloneOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            Write-Fail "$($item.NameWithOwner) failed to clone."
            $failed++
            if ([string]::IsNullOrWhiteSpace($details)) {
                $failureReason = "gh repo clone exited with code $cloneExitCode."
            }
            else {
                $failureReason = $details
            }

            $failures.Add([PSCustomObject]@{
                    Repository = $item.NameWithOwner
                    Reason     = $failureReason
                })
        }
    }

    Write-Progress -Activity 'Cloning GitHub repositories' -Completed

    return [PSCustomObject]@{
        Cloned   = $cloned
        Skipped  = $skipped
        Failed   = $failed
        Failures = @($failures)
    }
}

function Show-FinalSummary {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][string]$ProjectsRoot
    )

    Write-Section 'Completed'
    Write-Host "Projects root : $ProjectsRoot"
    Write-Host ''
    Write-Host "Cloned  : $($Result.Cloned)" -ForegroundColor Green
    Write-Host "Skipped : $($Result.Skipped)" -ForegroundColor Yellow

    if ($Result.Failed -gt 0) {
        Write-Host "Failed  : $($Result.Failed)" -ForegroundColor Red
    }
    else {
        Write-Host 'Failed  : 0' -ForegroundColor Green
    }

    if ($Result.Failures.Count -gt 0) {
        Write-Host ''
        Write-Host 'Failed repositories:' -ForegroundColor Red

        foreach ($failure in $Result.Failures) {
            Write-Host "  - $($failure.Repository)"
            Write-Host "    $($failure.Reason)" -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Credit
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function Main {
    try {
        Write-Section 'GitHub Projects Workspace'
        Write-Host 'Creates a fresh projects workspace and clones selected GitHub repository categories.'
        Write-Intro

        # Ask for the workspace location before performing any filesystem changes.
        $baseDirectory = Select-WorkspaceParent

        if ([string]::IsNullOrWhiteSpace($baseDirectory)) {
            Write-Info 'Directory selection cancelled.'
            return
        }

        $baseDirectory = [System.IO.Path]::GetFullPath($baseDirectory)
        $projectsRoot = Join-Path $baseDirectory 'projects'
        $githubRoot = Join-Path $projectsRoot 'github'

        # Validate tooling before deleting or creating the projects workspace.
        Test-Dependencies
        Test-GitHubAuthentication
        $username = Get-GitHubUsername

        $availableOrganizations = @(Get-GitHubOrganizations)
        $sourceSelection = Select-RepositoryCategories -Organizations $availableOrganizations
        $categories = @($sourceSelection.Categories)
        $selectedOrganizations = @($sourceSelection.Organizations)

        $repositories = @(
            Get-GitHubRepositories `
                -Username $username `
                -Organizations $selectedOrganizations
        )

        $clonePlan = @(
            New-ClonePlan `
                -Repositories $repositories `
                -Categories $categories `
                -Username $username `
                -GitHubRoot $githubRoot `
                -IncludeOrganizations $sourceSelection.IncludeOrganizations
        )

        Show-ClonePlan `
            -Plan $clonePlan `
            -Categories $categories `
            -Username $username `
            -ProjectsRoot $projectsRoot `
            -Organizations $selectedOrganizations

        if ($clonePlan.Count -eq 0) {
            Write-Host ''
            Write-Info 'No repositories matched the selected categories.'
            return
        }

        $selectedPlan = @(
            Select-ClonePlanItems -Plan $clonePlan
        )

        if ($selectedPlan.Count -eq 0) {
            Write-Info 'No repositories selected. Clone operation cancelled.'
            return
        }

        Show-ClonePlan `
            -Plan $selectedPlan `
            -Categories $categories `
            -Username $username `
            -ProjectsRoot $projectsRoot `
            -Organizations $selectedOrganizations

        Write-Host ''
        Show-WorkspaceChangeWarning -ProjectsRoot $projectsRoot
        if (-not (Confirm-YesNo -Prompt "Prepare the workspace and start cloning the selected $($selectedPlan.Count) repositories?" -DefaultYes $true)) {
            Write-Info 'Clone operation cancelled. No repositories were cloned.'
            return
        }

        $workspaceReady = Initialize-ProjectsWorkspace `
            -BaseDirectory $baseDirectory `
            -ProjectsRoot $projectsRoot `
            -GitHubRoot $githubRoot `
            -Confirmed

        if (-not $workspaceReady) {
            return
        }

        New-AgentsFile -ProjectsRoot $projectsRoot -Username $username

        if ($sourceSelection.IncludeOrganizations) {
            New-Item -ItemType Directory -Path (Join-Path $githubRoot 'organization') -Force | Out-Null
            Write-Ok 'Organization workspace directory created.'
        }

        $result = Invoke-ClonePlan -Plan $selectedPlan
        Show-FinalSummary -Result $result -ProjectsRoot $projectsRoot
    }
    catch {
        Write-Host ''
        Write-Fail $_.Exception.Message
        Write-Host ''
        exit 1
    }
}

Main
