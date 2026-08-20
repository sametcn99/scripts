#requires -Version 7.2

<#
.SYNOPSIS
    Interactive SMTP recipient reconnaissance TUI.

.DESCRIPTION
    Uses Terminal.Gui.dll bundled with Microsoft.PowerShell.ConsoleGuiTools.

    Workflow:
      1. Resolve MX records.
      2. Test random recipients for possible catch-all behavior.
      3. Test selected candidate local-parts with SMTP RCPT TO.
      4. Display results and optionally export them to CSV.

.NOTES
    SMTP RCPT probing is not definitive mailbox verification.

    Catch-all servers, greylisting, anti-enumeration systems and SMTP policy
    controls can cause false-positive or inconclusive results.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

$DefaultLocalParts = @(
    'careers'
    'career'
    'jobs'
    'job'
    'hr'
    'humanresources'
    'recruitment'
    'recruiting'
    'talent'
    'talentacquisition'
    'people'
    'peopleops'
    'work'
    'join'
    'joinus'
    'info'
    'contact'
    'hello'
)

$DefaultMailFrom       = 'probe@example.com'
$DefaultTimeoutSeconds = 10
$DefaultUseStartTls    = $true

$script:State = $null
$script:Ui = @{}

# -----------------------------------------------------------------------------
# Terminal.Gui bootstrap
# -----------------------------------------------------------------------------

function Import-TerminalGui {
    if ('Terminal.Gui.Application' -as [type]) {
        return
    }

    $module = Get-Module `
        -ListAvailable `
        -Name Microsoft.PowerShell.ConsoleGuiTools |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $module) {
        throw @'
Microsoft.PowerShell.ConsoleGuiTools is not installed.

Install it with:

    Install-Module Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser

Then run this script again from PowerShell 7.
'@
    }

    $nstackPath = Join-Path $module.ModuleBase 'NStack.dll'
    $guiPath    = Join-Path $module.ModuleBase 'Terminal.Gui.dll'

    if (-not (Test-Path $nstackPath)) {
        throw "NStack.dll was not found in $($module.ModuleBase)"
    }

    if (-not (Test-Path $guiPath)) {
        throw "Terminal.Gui.dll was not found in $($module.ModuleBase)"
    }

    Add-Type -Path $nstackPath
    Add-Type -Path $guiPath

    $version = [Terminal.Gui.Application].Assembly.GetName().Version

    if ($version.Major -ge 2) {
        throw @"
This script targets Terminal.Gui v1.

Loaded version:
    $version

The Microsoft.PowerShell.ConsoleGuiTools build uses the Terminal.Gui v1 API.
"@
    }
}

# -----------------------------------------------------------------------------
# Application state
# -----------------------------------------------------------------------------

function New-AppState {
    $candidates = [System.Collections.ArrayList]::new()

    foreach ($part in $DefaultLocalParts) {
        [void]$candidates.Add($part)
    }

    [PSCustomObject]@{
        Domain         = ''
        MailFrom       = $DefaultMailFrom
        TimeoutSeconds = $DefaultTimeoutSeconds
        UseStartTls    = $DefaultUseStartTls
        Candidates     = $candidates
        Audit          = $null
        MxServers      = @()
        IsScanning     = $false
    }
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

function Test-DomainName {
    param(
        [Parameter(Mandatory)]
        [string]$Domain
    )

    return $Domain -match '^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$'
}

function Test-MailboxAddress {
    param(
        [Parameter(Mandatory)]
        [string]$Address
    )

    return $Address -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
}

function Sync-StateFromControls {
    $script:State.Domain = (
        $script:Ui.DomainField.Text.ToString().Trim().ToLowerInvariant().TrimEnd('.')
    )

    $script:State.MailFrom = (
        $script:Ui.MailFromField.Text.ToString().Trim()
    )

    $timeoutText = $script:Ui.TimeoutField.Text.ToString().Trim()
    $timeout = 0

    if ([int]::TryParse($timeoutText, [ref]$timeout)) {
        $script:State.TimeoutSeconds = $timeout
    }
    else {
        $script:State.TimeoutSeconds = 0
    }

    $script:State.UseStartTls = (
        $script:Ui.StartTlsCheck.Checked -eq $true
    )
}

function Get-ConfigurationError {
    Sync-StateFromControls

    if ([string]::IsNullOrWhiteSpace($script:State.Domain)) {
        return 'Domain is required.'
    }

    if (-not (Test-DomainName $script:State.Domain)) {
        return 'Domain is not valid. Example: example.com'
    }

    if ([string]::IsNullOrWhiteSpace($script:State.MailFrom)) {
        return 'MAIL FROM is required.'
    }

    if (-not (Test-MailboxAddress $script:State.MailFrom)) {
        return 'MAIL FROM must be a valid email address.'
    }

    if (
        $script:State.TimeoutSeconds -lt 1 -or
        $script:State.TimeoutSeconds -gt 300
    ) {
        return 'Timeout must be between 1 and 300 seconds.'
    }

    if ((Get-SelectedCandidates).Count -eq 0) {
        return 'Select at least one candidate local-part.'
    }

    return $null
}

# -----------------------------------------------------------------------------
# Basic UI helpers
# -----------------------------------------------------------------------------

function Set-UiStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($script:Ui.StatusLabel) {
        $script:Ui.StatusLabel.Text = $Message
        $script:Ui.StatusLabel.SetNeedsDisplay()
    }
}

function Invoke-UiPaint {
    <#
        The SMTP code intentionally remains synchronous.

        This forces Terminal.Gui to repaint the current frame between
        network operations so progress is still visible.
    #>

    try {
        $script:Ui.Window.SetNeedsDisplay()
        $script:Ui.Window.Redraw($script:Ui.Window.Bounds)
        [Terminal.Gui.Application]::Driver.Refresh()
    }
    catch {
        # Repaint failures must never abort the actual scan.
    }
}

function Show-Info {
    param(
        [string]$Title,
        [string]$Message
    )

    [void][Terminal.Gui.MessageBox]::Query(
        70,
        8,
        $Title,
        $Message,
        'OK'
    )
}

function Show-Error {
    param(
        [string]$Title,
        [string]$Message
    )

    [void][Terminal.Gui.MessageBox]::ErrorQuery(
        70,
        8,
        $Title,
        $Message,
        'OK'
    )
}

function Confirm-Action {
    param(
        [string]$Title,
        [string]$Message
    )

    $result = [Terminal.Gui.MessageBox]::Query(
        60,
        8,
        $Title,
        $Message,
        'Yes',
        'No'
    )

    return $result -eq 0
}

# -----------------------------------------------------------------------------
# Candidate list
# -----------------------------------------------------------------------------

function Get-CandidateMarks {
    $marks = @{}

    if (-not $script:Ui.CandidateList) {
        foreach ($candidate in $script:State.Candidates) {
            $marks[[string]$candidate] = $true
        }

        return $marks
    }

    $source = $script:Ui.CandidateList.Source

    for ($i = 0; $i -lt $script:State.Candidates.Count; $i++) {
        $candidate = [string]$script:State.Candidates[$i]

        $marks[$candidate] = if ($source) {
            $source.IsMarked($i)
        }
        else {
            $true
        }
    }

    return $marks
}

function Set-CandidateSource {
    param(
        [hashtable]$Marks
    )

    $items = [System.Collections.ArrayList]::new()

    foreach ($candidate in $script:State.Candidates) {
        [void]$items.Add([string]$candidate)
    }

    $script:Ui.CandidateList.SetSource($items)

    for ($i = 0; $i -lt $script:State.Candidates.Count; $i++) {
        $candidate = [string]$script:State.Candidates[$i]

        $mark = if ($null -eq $Marks) {
            $true
        }
        elseif ($Marks.ContainsKey($candidate)) {
            [bool]$Marks[$candidate]
        }
        else {
            $true
        }

        $script:Ui.CandidateList.Source.SetMark($i, $mark)
    }

    Update-CandidateCount
}

function Get-SelectedCandidates {
    $selected = [System.Collections.Generic.List[string]]::new()

    if (
        -not $script:Ui.CandidateList -or
        -not $script:Ui.CandidateList.Source
    ) {
        foreach ($candidate in $script:State.Candidates) {
            [void]$selected.Add([string]$candidate)
        }

        return @($selected)
    }

    for ($i = 0; $i -lt $script:State.Candidates.Count; $i++) {
        if ($script:Ui.CandidateList.Source.IsMarked($i)) {
            [void]$selected.Add(
                [string]$script:State.Candidates[$i]
            )
        }
    }

    return @($selected)
}

function Update-CandidateCount {
    if (-not $script:Ui.CandidateCountLabel) {
        return
    }

    $selected = (Get-SelectedCandidates).Count
    $total = $script:State.Candidates.Count

    $script:Ui.CandidateCountLabel.Text =
        "Selected: $selected / $total"
}

function Add-CandidateFromInput {
    $raw = $script:Ui.CandidateInput.Text.ToString().Trim()

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return
    }

    $marks = Get-CandidateMarks
    $added = 0

    foreach ($value in ($raw -split '[,;\s]+')) {
        $clean = $value.Trim().ToLowerInvariant()

        if ([string]::IsNullOrWhiteSpace($clean)) {
            continue
        }

        if ($clean -notmatch '^[^@\s]+$') {
            continue
        }

        $exists = @(
            $script:State.Candidates |
            Where-Object { $_ -eq $clean }
        ).Count -gt 0

        if ($exists) {
            continue
        }

        [void]$script:State.Candidates.Add($clean)
        $marks[$clean] = $true
        $added++
    }

    $script:Ui.CandidateInput.Text = ''

    Set-CandidateSource -Marks $marks

    if ($added -gt 0) {
        Set-UiStatus "$added candidate(s) added."
    }
    else {
        Set-UiStatus 'No new valid candidates were added.'
    }
}

function Remove-SelectedCandidate {
    if ($script:State.Candidates.Count -eq 0) {
        return
    }

    $index = $script:Ui.CandidateList.SelectedItem

    if (
        $index -lt 0 -or
        $index -ge $script:State.Candidates.Count
    ) {
        return
    }

    $candidate = [string]$script:State.Candidates[$index]

    if (
        -not (
            Confirm-Action `
                -Title 'Remove candidate' `
                -Message "Remove '$candidate'?"
        )
    ) {
        return
    }

    $marks = Get-CandidateMarks
    $script:State.Candidates.RemoveAt($index)
    $marks.Remove($candidate)

    Set-CandidateSource -Marks $marks

    if ($script:State.Candidates.Count -gt 0) {
        $script:Ui.CandidateList.SelectedItem = [Math]::Min(
            $index,
            $script:State.Candidates.Count - 1
        )
    }

    Set-UiStatus "Removed '$candidate'."
}

function Reset-Candidates {
    if (
        -not (
            Confirm-Action `
                -Title 'Reset candidates' `
                -Message 'Restore the default candidate list?'
        )
    ) {
        return
    }

    $script:State.Candidates.Clear()

    foreach ($part in $DefaultLocalParts) {
        [void]$script:State.Candidates.Add($part)
    }

    Set-CandidateSource
    Set-UiStatus 'Default candidate list restored.'
}

function Select-AllCandidates {
    $source = $script:Ui.CandidateList.Source

    for ($i = 0; $i -lt $script:State.Candidates.Count; $i++) {
        $source.SetMark($i, $true)
    }

    Update-CandidateCount
    $script:Ui.CandidateList.SetNeedsDisplay()
}

function Select-NoCandidates {
    $source = $script:Ui.CandidateList.Source

    for ($i = 0; $i -lt $script:State.Candidates.Count; $i++) {
        $source.SetMark($i, $false)
    }

    Update-CandidateCount
    $script:Ui.CandidateList.SetNeedsDisplay()
}

# -----------------------------------------------------------------------------
# SMTP
# -----------------------------------------------------------------------------

function Get-SmtpResponse {
    param(
        [Parameter(Mandatory)]
        [System.IO.StreamReader]$Reader
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    $firstLine = $Reader.ReadLine()

    if ($null -eq $firstLine) {
        throw 'SMTP server closed the connection.'
    }

    [void]$lines.Add($firstLine)

    if ($firstLine -notmatch '^(\d{3})([- ])') {
        return [PSCustomObject]@{
            Code  = 0
            Lines = @($lines)
            Text  = $firstLine
        }
    }

    $code = [int]$Matches[1]
    $separator = $Matches[2]

    if ($separator -eq '-') {
        while ($true) {
            $line = $Reader.ReadLine()

            if ($null -eq $line) {
                break
            }

            [void]$lines.Add($line)

            if ($line -match "^$code ") {
                break
            }
        }
    }

    [PSCustomObject]@{
        Code  = $code
        Lines = @($lines)
        Text  = $lines -join ' | '
    }
}

function Send-SmtpCommand {
    param(
        [Parameter(Mandatory)]
        [System.IO.StreamWriter]$Writer,

        [Parameter(Mandatory)]
        [System.IO.StreamReader]$Reader,

        [Parameter(Mandatory)]
        [string]$Command
    )

    $Writer.WriteLine($Command)
    $Writer.Flush()

    Get-SmtpResponse -Reader $Reader
}

function Get-MxServers {
    param(
        [Parameter(Mandatory)]
        [string]$Domain
    )

    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
        throw 'Resolve-DnsName is not available on this PowerShell installation.'
    }

    $records = Resolve-DnsName `
        -Name $Domain `
        -Type MX `
        -ErrorAction Stop |
        Where-Object {
            $_.Type -eq 'MX'
        } |
        Sort-Object Preference

    foreach ($record in $records) {
        [PSCustomObject]@{
            Preference = $record.Preference
            Host       = $record.NameExchange.TrimEnd('.')
        }
    }
}

function Test-SmtpRecipient {
    param(
        [Parameter(Mandatory)]
        [string]$MxHost,

        [Parameter(Mandatory)]
        [string]$Address,

        [Parameter(Mandatory)]
        [string]$MailFrom,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [bool]$UseStartTls
    )

    $client = $null
    $reader = $null
    $writer = $null
    $sslStream = $null

    try {
        $timeoutMs = $TimeoutSeconds * 1000

        $client = [System.Net.Sockets.TcpClient]::new()

        $connectTask = $client.ConnectAsync(
            $MxHost,
            25
        )

        if (-not $connectTask.Wait($timeoutMs)) {
            throw "Connection timeout to $MxHost`:25"
        }

        $stream = $client.GetStream()

        $stream.ReadTimeout = $timeoutMs
        $stream.WriteTimeout = $timeoutMs

        $reader = [System.IO.StreamReader]::new(
            $stream,
            [System.Text.Encoding]::ASCII,
            $false,
            1024,
            $true
        )

        $writer = [System.IO.StreamWriter]::new(
            $stream,
            [System.Text.Encoding]::ASCII,
            1024,
            $true
        )

        $writer.NewLine = "`r`n"
        $writer.AutoFlush = $true

        $banner = Get-SmtpResponse -Reader $reader

        if ($banner.Code -ne 220) {
            throw "Unexpected SMTP banner: $($banner.Text)"
        }

        $ehloHost = [System.Net.Dns]::GetHostName()

        $ehlo = Send-SmtpCommand `
            -Writer $writer `
            -Reader $reader `
            -Command "EHLO $ehloHost"

        if (
            $UseStartTls -and
            ($ehlo.Lines -match '(?i)STARTTLS')
        ) {
            $startTlsResponse = Send-SmtpCommand `
                -Writer $writer `
                -Reader $reader `
                -Command 'STARTTLS'

            if ($startTlsResponse.Code -eq 220) {
                $sslStream = [System.Net.Security.SslStream]::new(
                    $stream,
                    $false
                )

                $sslStream.AuthenticateAsClient($MxHost)

                $reader = [System.IO.StreamReader]::new(
                    $sslStream,
                    [System.Text.Encoding]::ASCII,
                    $false,
                    1024,
                    $true
                )

                $writer = [System.IO.StreamWriter]::new(
                    $sslStream,
                    [System.Text.Encoding]::ASCII,
                    1024,
                    $true
                )

                $writer.NewLine = "`r`n"
                $writer.AutoFlush = $true

                $null = Send-SmtpCommand `
                    -Writer $writer `
                    -Reader $reader `
                    -Command "EHLO $ehloHost"
            }
        }

        $mailFromResponse = Send-SmtpCommand `
            -Writer $writer `
            -Reader $reader `
            -Command "MAIL FROM:<$MailFrom>"

        if ($mailFromResponse.Code -notin 250, 251) {
            return [PSCustomObject]@{
                Address  = $Address
                Status   = 'PolicyBlocked'
                Code     = $mailFromResponse.Code
                Response = $mailFromResponse.Text
                MxHost   = $MxHost
            }
        }

        $recipientResponse = Send-SmtpCommand `
            -Writer $writer `
            -Reader $reader `
            -Command "RCPT TO:<$Address>"

        try {
            $null = Send-SmtpCommand `
                -Writer $writer `
                -Reader $reader `
                -Command 'QUIT'
        }
        catch {
            # RCPT TO result can still be used.
        }

        $status = switch ($recipientResponse.Code) {
            { $_ -in 250, 251 } {
                'Accepted'
                break
            }

            252 {
                'Unknown'
                break
            }

            { $_ -in 550, 551, 553 } {
                'Rejected'
                break
            }

            { $_ -ge 400 -and $_ -lt 500 } {
                'Temporary'
                break
            }

            { $_ -ge 500 -and $_ -lt 600 } {
                'PolicyBlocked'
                break
            }

            default {
                'Unknown'
            }
        }

        [PSCustomObject]@{
            Address  = $Address
            Status   = $status
            Code     = $recipientResponse.Code
            Response = $recipientResponse.Text
            MxHost   = $MxHost
        }
    }
    catch {
        [PSCustomObject]@{
            Address  = $Address
            Status   = 'Error'
            Code     = $null
            Response = $_.Exception.Message
            MxHost   = $MxHost
        }
    }
    finally {
        if ($writer) {
            try {
                $writer.Dispose()
            }
            catch {}
        }

        if ($reader) {
            try {
                $reader.Dispose()
            }
            catch {}
        }

        if ($sslStream) {
            try {
                $sslStream.Dispose()
            }
            catch {}
        }

        if ($client) {
            try {
                $client.Dispose()
            }
            catch {}
        }
    }
}

# -----------------------------------------------------------------------------
# Scan
# -----------------------------------------------------------------------------

function Get-UiConfiguration {
    Sync-StateFromControls

    [PSCustomObject]@{
        Domain         = $script:State.Domain
        MailFrom       = $script:State.MailFrom
        TimeoutSeconds = $script:State.TimeoutSeconds
        UseStartTls    = $script:State.UseStartTls
        LocalParts     = @(Get-SelectedCandidates)
    }
}

function Update-ScanProgress {
    param(
        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        [string]$Current,

        [Parameter(Mandatory)]
        [int]$Percent
    )

    $percent = [Math]::Max(
        0,
        [Math]::Min(100, $Percent)
    )

    $script:Ui.Progress.Fraction = [float]($percent / 100.0)

    $script:Ui.ProgressPercent.Text = "$percent%"
    $script:Ui.ProgressPhase.Text   = $Phase
    $script:Ui.ProgressCurrent.Text = $Current

    Set-UiStatus "$Phase - $Current"

    Invoke-UiPaint
}

function Invoke-DomainEmailScan {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Configuration
    )

    $startedAt = Get-Date

    Update-ScanProgress `
        -Phase 'DNS / MX lookup' `
        -Current $Configuration.Domain `
        -Percent 5

    $mxServers = @(
        Get-MxServers -Domain $Configuration.Domain
    )

    if ($mxServers.Count -eq 0) {
        throw "No MX records found for $($Configuration.Domain)."
    }

    $script:State.MxServers = $mxServers

    $mxHost = $mxServers[0].Host

    $randomAddresses = 1..2 |
        ForEach-Object {
            "does-not-exist-$([guid]::NewGuid().ToString('N'))@$($Configuration.Domain)"
        }

    $catchAllResults =
        [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $randomAddresses.Count; $i++) {
        $address = $randomAddresses[$i]

        $percent = 10 + [int](
            (($i + 1) / $randomAddresses.Count) * 25
        )

        Update-ScanProgress `
            -Phase 'Catch-all detection' `
            -Current $address `
            -Percent $percent

        $result = Test-SmtpRecipient `
            -MxHost $mxHost `
            -Address $address `
            -MailFrom $Configuration.MailFrom `
            -TimeoutSeconds $Configuration.TimeoutSeconds `
            -UseStartTls $Configuration.UseStartTls

        [void]$catchAllResults.Add($result)
    }

    $catchAll = @(
        $catchAllResults |
        Where-Object Status -eq 'Accepted'
    ).Count -eq $randomAddresses.Count

    $results = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Configuration.LocalParts.Count; $i++) {
        $address =
            "$($Configuration.LocalParts[$i])@$($Configuration.Domain)"

        $percent = 35 + [int](
            (($i + 1) / $Configuration.LocalParts.Count) * 65
        )

        Update-ScanProgress `
            -Phase 'Testing candidate recipients' `
            -Current $address `
            -Percent $percent

        $result = Test-SmtpRecipient `
            -MxHost $mxHost `
            -Address $address `
            -MailFrom $Configuration.MailFrom `
            -TimeoutSeconds $Configuration.TimeoutSeconds `
            -UseStartTls $Configuration.UseStartTls

        if (
            $catchAll -and
            $result.Status -eq 'Accepted'
        ) {
            $result.Status = 'Accepted (Catch-All)'
        }

        [void]$results.Add($result)
    }

    Update-ScanProgress `
        -Phase 'Completed' `
        -Current $Configuration.Domain `
        -Percent 100

    [PSCustomObject]@{
        Configuration  = $Configuration
        MxServers      = $mxServers
        SelectedMxHost = $mxHost
        CatchAll       = $catchAll
        CatchAllResults = @($catchAllResults)
        Results        = @($results)
        StartedAt      = $startedAt
        CompletedAt    = Get-Date
    }
}

# -----------------------------------------------------------------------------
# Results
# -----------------------------------------------------------------------------

function Get-DefaultExportPath {
    $domain = if (
        [string]::IsNullOrWhiteSpace($script:State.Domain)
    ) {
        'scan'
    }
    else {
        $script:State.Domain
    }

    Join-Path `
        (Get-Location) `
        "domain-email-results-$domain-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}

function Update-ResultsUi {
    if (-not $script:State.Audit) {
        $script:Ui.ResultsSummary.Text = @'
No scan has been completed yet.

Configure the target, choose candidates and run a scan.
'@

        $empty = [System.Data.DataTable]::new()

        [void]$empty.Columns.Add('Address')
        [void]$empty.Columns.Add('Status')
        [void]$empty.Columns.Add('Code')
        [void]$empty.Columns.Add('MX Host')

        $script:Ui.ResultsTable.Table = $empty
        $script:Ui.ResultsDetails.Text = 'No SMTP responses available.'
        $script:Ui.ExportPathField.Text = ''

        return
    }

    $audit = $script:State.Audit

    $accepted = @(
        $audit.Results |
        Where-Object Status -Like 'Accepted*'
    ).Count

    $rejected = @(
        $audit.Results |
        Where-Object Status -eq 'Rejected'
    ).Count

    $temporary = @(
        $audit.Results |
        Where-Object Status -eq 'Temporary'
    ).Count

    $blocked = @(
        $audit.Results |
        Where-Object Status -eq 'PolicyBlocked'
    ).Count

    $errors = @(
        $audit.Results |
        Where-Object Status -eq 'Error'
    ).Count

    $duration = (
        $audit.CompletedAt -
        $audit.StartedAt
    ).TotalSeconds

    $catchAllText = if ($audit.CatchAll) {
        'Possible catch-all detected'
    }
    else {
        'Not detected'
    }

    $script:Ui.ResultsSummary.Text = @"
Domain: $($audit.Configuration.Domain)
MX: $($audit.SelectedMxHost)
Catch-all: $catchAllText
Accepted: $accepted    Rejected: $rejected    Temporary: $temporary    Policy blocked: $blocked    Errors: $errors
Duration: $([Math]::Round($duration, 2)) seconds
"@

    $table = [System.Data.DataTable]::new()

    [void]$table.Columns.Add('Address', [string])
    [void]$table.Columns.Add('Status',  [string])
    [void]$table.Columns.Add('Code',    [string])
    [void]$table.Columns.Add('MX Host', [string])

    foreach ($result in $audit.Results) {
        $code = if ($null -eq $result.Code) {
            ''
        }
        else {
            [string]$result.Code
        }

        [void]$table.Rows.Add(
            [string]$result.Address,
            [string]$result.Status,
            $code,
            [string]$result.MxHost
        )
    }

    $script:Ui.ResultsTable.Table = $table

    $detailBuilder = [System.Text.StringBuilder]::new()

    foreach ($result in $audit.Results) {
        [void]$detailBuilder.AppendLine(
            "Address : $($result.Address)"
        )

        [void]$detailBuilder.AppendLine(
            "Status  : $($result.Status)"
        )

        [void]$detailBuilder.AppendLine(
            "Code    : $($result.Code)"
        )

        [void]$detailBuilder.AppendLine(
            "MX      : $($result.MxHost)"
        )

        [void]$detailBuilder.AppendLine(
            "Reply   : $($result.Response)"
        )

        [void]$detailBuilder.AppendLine(
            ('-' * 72)
        )
    }

    $script:Ui.ResultsDetails.Text =
        $detailBuilder.ToString()

    $script:Ui.ExportPathField.Text =
        Get-DefaultExportPath

    $script:Ui.ResultsPanel.SetNeedsDisplay()
}

function Export-Results {
    if (-not $script:State.Audit) {
        Show-Error `
            -Title 'Nothing to export' `
            -Message 'Run a scan before exporting results.'

        return
    }

    $path = $script:Ui.ExportPathField.Text.ToString().Trim()

    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Get-DefaultExportPath
        $script:Ui.ExportPathField.Text = $path
    }

    try {
        $script:State.Audit.Results |
            Select-Object `
                Address,
                Status,
                Code,
                MxHost,
                Response |
            Export-Csv `
                -Path $path `
                -NoTypeInformation `
                -Encoding UTF8

        $fullPath = [System.IO.Path]::GetFullPath($path)

        Set-UiStatus "CSV exported: $fullPath"

        Show-Info `
            -Title 'Export complete' `
            -Message $fullPath
    }
    catch {
        Show-Error `
            -Title 'Export failed' `
            -Message $_.Exception.Message
    }
}

# -----------------------------------------------------------------------------
# UI workflow
# -----------------------------------------------------------------------------

function Update-ScanSummary {
    Sync-StateFromControls

    $selected = (Get-SelectedCandidates).Count

    $startTls = if ($script:State.UseStartTls) {
        'Enabled'
    }
    else {
        'Disabled'
    }

    $domain = if (
        [string]::IsNullOrWhiteSpace($script:State.Domain)
    ) {
        '<not set>'
    }
    else {
        $script:State.Domain
    }

    $script:Ui.ScanSummary.Text = @"
Domain      : $domain
MAIL FROM   : $($script:State.MailFrom)
Timeout     : $($script:State.TimeoutSeconds) seconds
STARTTLS    : $startTls
Candidates  : $selected
"@
}

function Show-Panel {
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 3)]
        [int]$Index
    )

    $panels = @(
        $script:Ui.SetupPanel
        $script:Ui.CandidatesPanel
        $script:Ui.ScanPanel
        $script:Ui.ResultsPanel
    )

    for ($i = 0; $i -lt $panels.Count; $i++) {
        $panels[$i].Visible = ($i -eq $Index)
    }

    if ($script:Ui.NavList.SelectedItem -ne $Index) {
        $script:Ui.NavList.SelectedItem = $Index
    }

    switch ($Index) {
        0 {
            Set-UiStatus 'Configure the target and SMTP options.'
            $script:Ui.DomainField.SetFocus()
        }

        1 {
            Update-CandidateCount
            Set-UiStatus 'Space toggles candidates. Add or remove local-parts as needed.'
            $script:Ui.CandidateList.SetFocus()
        }

        2 {
            Update-ScanSummary
            Set-UiStatus 'Review the configuration and start the scan.'
            $script:Ui.RunButton.SetFocus()
        }

        3 {
            Update-ResultsUi
            Set-UiStatus 'Review results or export them to CSV.'
            $script:Ui.ResultsTable.SetFocus()
        }
    }

    $script:Ui.Window.SetNeedsDisplay()
}

function Invoke-UiScan {
    if ($script:State.IsScanning) {
        return
    }

    $validationError = Get-ConfigurationError

    if ($validationError) {
        Show-Error `
            -Title 'Invalid configuration' `
            -Message $validationError

        return
    }

    Show-Panel -Index 2

    $configuration = Get-UiConfiguration

    $script:State.IsScanning = $true
    $script:Ui.RunButton.Enabled = $false

    $script:Ui.Progress.Fraction = 0
    $script:Ui.ProgressPercent.Text = '0%'
    $script:Ui.ProgressPhase.Text = 'Preparing...'
    $script:Ui.ProgressCurrent.Text = $configuration.Domain

    try {
        $audit = Invoke-DomainEmailScan `
            -Configuration $configuration

        $script:State.Audit = $audit

        Update-ResultsUi

        Set-UiStatus "Scan completed for $($configuration.Domain)."

        Show-Panel -Index 3
    }
    catch {
        Set-UiStatus "Scan failed: $($_.Exception.Message)"

        Show-Error `
            -Title 'Scan failed' `
            -Message $_.Exception.Message
    }
    finally {
        $script:State.IsScanning = $false
        $script:Ui.RunButton.Enabled = $true
    }
}

function Reset-Application {
    if (
        $script:State.Audit -or
        -not [string]::IsNullOrWhiteSpace(
            $script:Ui.DomainField.Text.ToString()
        )
    ) {
        if (
            -not (
                Confirm-Action `
                    -Title 'New scan' `
                    -Message 'Clear the current scan and start again?'
            )
        ) {
            return
        }
    }

    $script:State = New-AppState

    $script:Ui.DomainField.Text = ''
    $script:Ui.MailFromField.Text = $DefaultMailFrom
    $script:Ui.TimeoutField.Text = [string]$DefaultTimeoutSeconds
    $script:Ui.StartTlsCheck.Checked = $DefaultUseStartTls
    $script:Ui.CandidateInput.Text = ''

    Set-CandidateSource

    $script:Ui.Progress.Fraction = 0
    $script:Ui.ProgressPercent.Text = '0%'
    $script:Ui.ProgressPhase.Text = 'Ready'
    $script:Ui.ProgressCurrent.Text = ''

    Update-ResultsUi
    Update-ScanSummary

    Show-Panel -Index 0

    Set-UiStatus 'Ready for a new scan.'
}

function Request-ApplicationExit {
    if ($script:State.IsScanning) {
        Show-Info `
            -Title 'Scan running' `
            -Message 'Wait for the current SMTP operation to finish.'

        return
    }

    if (
        Confirm-Action `
            -Title 'Exit' `
            -Message 'Exit Domain Email Reconnaissance?'
    ) {
        [Terminal.Gui.Application]::RequestStop()
    }
}

# -----------------------------------------------------------------------------
# Build UI
# -----------------------------------------------------------------------------

function Initialize-TerminalUi {
    [Terminal.Gui.Application]::Init()

    $top = [Terminal.Gui.Application]::Top

    # -------------------------------------------------------------------------
    # Main window
    # -------------------------------------------------------------------------

    $window = [Terminal.Gui.Window]::new(
        'Domain Email Reconnaissance'
    )

    $window.X = 0
    $window.Y = 0
    $window.Width = [Terminal.Gui.Dim]::Fill()
    $window.Height = [Terminal.Gui.Dim]::Fill()

    $script:Ui.Window = $window

    $top.Add($window)

    # -------------------------------------------------------------------------
    # Sidebar
    # -------------------------------------------------------------------------

    $sidebar = [Terminal.Gui.FrameView]::new(
        'Workflow'
    )

    $sidebar.X = 0
    $sidebar.Y = 0
    $sidebar.Width = 26
    $sidebar.Height = [Terminal.Gui.Dim]::Fill(3)

    $navList = [Terminal.Gui.ListView]::new()

    $navList.X = 0
    $navList.Y = 0
    $navList.Width = [Terminal.Gui.Dim]::Fill()
    $navList.Height = 8

    $navItems = [System.Collections.ArrayList]::new()

    [void]$navItems.Add('1  Setup')
    [void]$navItems.Add('2  Candidates')
    [void]$navItems.Add('3  Run scan')
    [void]$navItems.Add('4  Results')

    $navList.SetSource($navItems)

    $sidebarHint = [Terminal.Gui.Label]::new(
@'
Keyboard

↑ ↓   Navigate
Tab   Next control
Space Mark/unmark
Enter Activate

Mouse is supported.
'@
    )

    $sidebarHint.X = 1
    $sidebarHint.Y = 10
    $sidebarHint.Width = [Terminal.Gui.Dim]::Fill(1)
    $sidebarHint.Height = 9

    $sidebar.Add($navList)
    $sidebar.Add($sidebarHint)

    $script:Ui.Sidebar = $sidebar
    $script:Ui.NavList = $navList

    $window.Add($sidebar)

    # -------------------------------------------------------------------------
    # Setup panel
    # -------------------------------------------------------------------------

    $setupPanel = [Terminal.Gui.FrameView]::new(
        'Setup'
    )

    $setupPanel.X = 26
    $setupPanel.Y = 0
    $setupPanel.Width = [Terminal.Gui.Dim]::Fill()
    $setupPanel.Height = [Terminal.Gui.Dim]::Fill(3)

    $targetFrame = [Terminal.Gui.FrameView]::new(
        'Target'
    )

    $targetFrame.X = 0
    $targetFrame.Y = 0
    $targetFrame.Width = [Terminal.Gui.Dim]::Fill()
    $targetFrame.Height = 7

    $domainLabel = [Terminal.Gui.Label]::new('Domain')
    $domainLabel.X = 2
    $domainLabel.Y = 1
    $domainLabel.Width = 14

    $domainField = [Terminal.Gui.TextField]::new()
    $domainField.X = 18
    $domainField.Y = 1
    $domainField.Width = [Terminal.Gui.Dim]::Fill(2)
    $domainField.Text = ''

    $domainExample = [Terminal.Gui.Label]::new(
        'Example: example.com'
    )

    $domainExample.X = 18
    $domainExample.Y = 3
    $domainExample.Width = [Terminal.Gui.Dim]::Fill(2)

    $targetFrame.Add($domainLabel)
    $targetFrame.Add($domainField)
    $targetFrame.Add($domainExample)

    $smtpFrame = [Terminal.Gui.FrameView]::new(
        'SMTP options'
    )

    $smtpFrame.X = 0
    $smtpFrame.Y = 7
    $smtpFrame.Width = [Terminal.Gui.Dim]::Fill()
    $smtpFrame.Height = 9

    $mailFromLabel = [Terminal.Gui.Label]::new(
        'MAIL FROM'
    )

    $mailFromLabel.X = 2
    $mailFromLabel.Y = 1
    $mailFromLabel.Width = 14

    $mailFromField = [Terminal.Gui.TextField]::new()

    $mailFromField.X = 18
    $mailFromField.Y = 1
    $mailFromField.Width = [Terminal.Gui.Dim]::Fill(2)
    $mailFromField.Text = $DefaultMailFrom

    $timeoutLabel = [Terminal.Gui.Label]::new(
        'Timeout (sec)'
    )

    $timeoutLabel.X = 2
    $timeoutLabel.Y = 3
    $timeoutLabel.Width = 14

    $timeoutField = [Terminal.Gui.TextField]::new()

    $timeoutField.X = 18
    $timeoutField.Y = 3
    $timeoutField.Width = 10
    $timeoutField.Text = [string]$DefaultTimeoutSeconds

    $startTlsCheck = [Terminal.Gui.CheckBox]::new(
        'Use STARTTLS when offered',
        $DefaultUseStartTls
    )

    $startTlsCheck.X = 18
    $startTlsCheck.Y = 5

    $smtpFrame.Add($mailFromLabel)
    $smtpFrame.Add($mailFromField)
    $smtpFrame.Add($timeoutLabel)
    $smtpFrame.Add($timeoutField)
    $smtpFrame.Add($startTlsCheck)

    $setupHint = [Terminal.Gui.Label]::new(
        'The target MX server will be selected by DNS preference.'
    )

    $setupHint.X = 2
    $setupHint.Y = 17
    $setupHint.Width = [Terminal.Gui.Dim]::Fill(2)
    $setupHint.Height = 2

    $setupContinue = [Terminal.Gui.Button]::new(
        '_Continue to candidates'
    )

    $setupContinue.X = 2
    $setupContinue.Y = [Terminal.Gui.Pos]::AnchorEnd(2)

    $setupContinue.add_Clicked(
        [System.Action]{
            Sync-StateFromControls
            Show-Panel -Index 1
        }
    )

    $setupPanel.Add($targetFrame)
    $setupPanel.Add($smtpFrame)
    $setupPanel.Add($setupHint)
    $setupPanel.Add($setupContinue)

    $script:Ui.SetupPanel = $setupPanel
    $script:Ui.DomainField = $domainField
    $script:Ui.MailFromField = $mailFromField
    $script:Ui.TimeoutField = $timeoutField
    $script:Ui.StartTlsCheck = $startTlsCheck

    $window.Add($setupPanel)

    # -------------------------------------------------------------------------
    # Candidates panel
    # -------------------------------------------------------------------------

    $candidatesPanel = [Terminal.Gui.FrameView]::new(
        'Candidate local-parts'
    )

    $candidatesPanel.X = 26
    $candidatesPanel.Y = 0
    $candidatesPanel.Width = [Terminal.Gui.Dim]::Fill()
    $candidatesPanel.Height = [Terminal.Gui.Dim]::Fill(3)
    $candidatesPanel.Visible = $false

    $candidateInputLabel = [Terminal.Gui.Label]::new(
        'Add'
    )

    $candidateInputLabel.X = 1
    $candidateInputLabel.Y = 1
    $candidateInputLabel.Width = 5

    $candidateInput = [Terminal.Gui.TextField]::new()

    $candidateInput.X = 7
    $candidateInput.Y = 1
    $candidateInput.Width = [Terminal.Gui.Dim]::Fill(16)

    $addCandidateButton = [Terminal.Gui.Button]::new(
        '_Add'
    )

    $addCandidateButton.X =
        [Terminal.Gui.Pos]::AnchorEnd(13)

    $addCandidateButton.Y = 1

    $candidateCountLabel = [Terminal.Gui.Label]::new(
        'Selected: 0 / 0'
    )

    $candidateCountLabel.X = 1
    $candidateCountLabel.Y = 3
    $candidateCountLabel.Width = 30

    $candidateList = [Terminal.Gui.ListView]::new()

    $candidateList.X = 1
    $candidateList.Y = 5
    $candidateList.Width = [Terminal.Gui.Dim]::Fill(1)
    $candidateList.Height = [Terminal.Gui.Dim]::Fill(5)

    $candidateList.AllowsMarking = $true
    $candidateList.AllowsMultipleSelection = $true

    $removeButton = [Terminal.Gui.Button]::new(
        '_Remove'
    )

    $removeButton.X = 1
    $removeButton.Y = [Terminal.Gui.Pos]::AnchorEnd(3)

    $resetButton = [Terminal.Gui.Button]::new(
        'R_eset'
    )

    $resetButton.X = 13
    $resetButton.Y = [Terminal.Gui.Pos]::AnchorEnd(3)

    $allButton = [Terminal.Gui.Button]::new(
        'Select _all'
    )

    $allButton.X = 24
    $allButton.Y = [Terminal.Gui.Pos]::AnchorEnd(3)

    $noneButton = [Terminal.Gui.Button]::new(
        'Select _none'
    )

    $noneButton.X = 39
    $noneButton.Y = [Terminal.Gui.Pos]::AnchorEnd(3)

    $candidateContinue = [Terminal.Gui.Button]::new(
        'Continue to _scan'
    )

    $candidateContinue.X =
        [Terminal.Gui.Pos]::AnchorEnd(21)

    $candidateContinue.Y =
        [Terminal.Gui.Pos]::AnchorEnd(3)

    $candidateHint = [Terminal.Gui.Label]::new(
        'Space toggles the selected local-part.'
    )

    $candidateHint.X = 1
    $candidateHint.Y = [Terminal.Gui.Pos]::AnchorEnd(1)
    $candidateHint.Width = [Terminal.Gui.Dim]::Fill(1)

    $script:Ui.CandidatesPanel = $candidatesPanel
    $script:Ui.CandidateInput = $candidateInput
    $script:Ui.CandidateList = $candidateList
    $script:Ui.CandidateCountLabel = $candidateCountLabel

    $addCandidateButton.add_Clicked(
        [System.Action]{
            Add-CandidateFromInput
        }
    )

    $candidateInput.add_Enter(
        {
            Update-CandidateCount
        }
    )

    $candidateList.add_KeyUp(
        {
            Update-CandidateCount
        }
    )

    $removeButton.add_Clicked(
        [System.Action]{
            Remove-SelectedCandidate
        }
    )

    $resetButton.add_Clicked(
        [System.Action]{
            Reset-Candidates
        }
    )

    $allButton.add_Clicked(
        [System.Action]{
            Select-AllCandidates
        }
    )

    $noneButton.add_Clicked(
        [System.Action]{
            Select-NoCandidates
        }
    )

    $candidateContinue.add_Clicked(
        [System.Action]{
            Update-CandidateCount
            Show-Panel -Index 2
        }
    )

    $candidatesPanel.Add($candidateInputLabel)
    $candidatesPanel.Add($candidateInput)
    $candidatesPanel.Add($addCandidateButton)
    $candidatesPanel.Add($candidateCountLabel)
    $candidatesPanel.Add($candidateList)
    $candidatesPanel.Add($removeButton)
    $candidatesPanel.Add($resetButton)
    $candidatesPanel.Add($allButton)
    $candidatesPanel.Add($noneButton)
    $candidatesPanel.Add($candidateContinue)
    $candidatesPanel.Add($candidateHint)

    $window.Add($candidatesPanel)

    Set-CandidateSource

    # -------------------------------------------------------------------------
    # Scan panel
    # -------------------------------------------------------------------------

    $scanPanel = [Terminal.Gui.FrameView]::new(
        'Run scan'
    )

    $scanPanel.X = 26
    $scanPanel.Y = 0
    $scanPanel.Width = [Terminal.Gui.Dim]::Fill()
    $scanPanel.Height = [Terminal.Gui.Dim]::Fill(3)
    $scanPanel.Visible = $false

    $configFrame = [Terminal.Gui.FrameView]::new(
        'Configuration'
    )

    $configFrame.X = 0
    $configFrame.Y = 0
    $configFrame.Width = [Terminal.Gui.Dim]::Fill()
    $configFrame.Height = 9

    $scanSummary = [Terminal.Gui.TextView]::new()

    $scanSummary.X = 1
    $scanSummary.Y = 1
    $scanSummary.Width = [Terminal.Gui.Dim]::Fill(1)
    $scanSummary.Height = [Terminal.Gui.Dim]::Fill(1)
    $scanSummary.ReadOnly = $true
    $scanSummary.WordWrap = $true

    $configFrame.Add($scanSummary)

    $progressFrame = [Terminal.Gui.FrameView]::new(
        'Progress'
    )

    $progressFrame.X = 0
    $progressFrame.Y = 9
    $progressFrame.Width = [Terminal.Gui.Dim]::Fill()
    $progressFrame.Height = 8

    $progress = [Terminal.Gui.ProgressBar]::new()

    $progress.X = 1
    $progress.Y = 1
    $progress.Width = [Terminal.Gui.Dim]::Fill(8)
    $progress.Fraction = 0

    $progressPercent = [Terminal.Gui.Label]::new(
        '0%'
    )

    $progressPercent.X =
        [Terminal.Gui.Pos]::AnchorEnd(6)

    $progressPercent.Y = 1
    $progressPercent.Width = 5

    $phaseCaption = [Terminal.Gui.Label]::new(
        'Phase'
    )

    $phaseCaption.X = 1
    $phaseCaption.Y = 3
    $phaseCaption.Width = 10

    $progressPhase = [Terminal.Gui.Label]::new(
        'Ready'
    )

    $progressPhase.X = 12
    $progressPhase.Y = 3
    $progressPhase.Width =
        [Terminal.Gui.Dim]::Fill(1)

    $currentCaption = [Terminal.Gui.Label]::new(
        'Current'
    )

    $currentCaption.X = 1
    $currentCaption.Y = 5
    $currentCaption.Width = 10

    $progressCurrent = [Terminal.Gui.Label]::new(
        ''
    )

    $progressCurrent.X = 12
    $progressCurrent.Y = 5
    $progressCurrent.Width =
        [Terminal.Gui.Dim]::Fill(1)

    $progressFrame.Add($progress)
    $progressFrame.Add($progressPercent)
    $progressFrame.Add($phaseCaption)
    $progressFrame.Add($progressPhase)
    $progressFrame.Add($currentCaption)
    $progressFrame.Add($progressCurrent)

    $runButton = [Terminal.Gui.Button]::new(
        '_Run scan'
    )

    $runButton.X = 2
    $runButton.Y = [Terminal.Gui.Pos]::AnchorEnd(2)

    $runButton.add_Clicked(
        [System.Action]{
            Invoke-UiScan
        }
    )

    $scanPanel.Add($configFrame)
    $scanPanel.Add($progressFrame)
    $scanPanel.Add($runButton)

    $script:Ui.ScanPanel = $scanPanel
    $script:Ui.ScanSummary = $scanSummary
    $script:Ui.Progress = $progress
    $script:Ui.ProgressPercent = $progressPercent
    $script:Ui.ProgressPhase = $progressPhase
    $script:Ui.ProgressCurrent = $progressCurrent
    $script:Ui.RunButton = $runButton

    $window.Add($scanPanel)

    # -------------------------------------------------------------------------
    # Results panel
    # -------------------------------------------------------------------------

    $resultsPanel = [Terminal.Gui.FrameView]::new(
        'Results'
    )

    $resultsPanel.X = 26
    $resultsPanel.Y = 0
    $resultsPanel.Width = [Terminal.Gui.Dim]::Fill()
    $resultsPanel.Height = [Terminal.Gui.Dim]::Fill(3)
    $resultsPanel.Visible = $false

    $resultsSummaryFrame = [Terminal.Gui.FrameView]::new(
        'Summary'
    )

    $resultsSummaryFrame.X = 0
    $resultsSummaryFrame.Y = 0
    $resultsSummaryFrame.Width =
        [Terminal.Gui.Dim]::Fill()

    $resultsSummaryFrame.Height = 9

    $resultsSummary = [Terminal.Gui.Label]::new(
        'No scan has been completed yet.'
    )

    $resultsSummary.X = 1
    $resultsSummary.Y = 1
    $resultsSummary.Width =
        [Terminal.Gui.Dim]::Fill(1)

    $resultsSummary.Height = 5

    $exportLabel = [Terminal.Gui.Label]::new(
        'CSV'
    )

    $exportLabel.X = 1
    $exportLabel.Y = 6
    $exportLabel.Width = 5

    $exportPathField = [Terminal.Gui.TextField]::new()

    $exportPathField.X = 7
    $exportPathField.Y = 6
    $exportPathField.Width =
        [Terminal.Gui.Dim]::Fill(18)

    $exportButton = [Terminal.Gui.Button]::new(
        '_Export CSV'
    )

    $exportButton.X =
        [Terminal.Gui.Pos]::AnchorEnd(15)

    $exportButton.Y = 6

    $exportButton.add_Clicked(
        [System.Action]{
            Export-Results
        }
    )

    $resultsSummaryFrame.Add($resultsSummary)
    $resultsSummaryFrame.Add($exportLabel)
    $resultsSummaryFrame.Add($exportPathField)
    $resultsSummaryFrame.Add($exportButton)

    $tableFrame = [Terminal.Gui.FrameView]::new(
        'Recipient results'
    )

    $tableFrame.X = 0
    $tableFrame.Y = 9
    $tableFrame.Width =
        [Terminal.Gui.Dim]::Fill()

    $tableFrame.Height =
        [Terminal.Gui.Dim]::Fill(10)

    $resultsTable = [Terminal.Gui.TableView]::new()

    $resultsTable.X = 0
    $resultsTable.Y = 0
    $resultsTable.Width =
        [Terminal.Gui.Dim]::Fill()

    $resultsTable.Height =
        [Terminal.Gui.Dim]::Fill()

    $tableFrame.Add($resultsTable)

    $detailsFrame = [Terminal.Gui.FrameView]::new(
        'SMTP responses'
    )

    $detailsFrame.X = 0
    $detailsFrame.Y =
        [Terminal.Gui.Pos]::AnchorEnd(10)

    $detailsFrame.Width =
        [Terminal.Gui.Dim]::Fill()

    $detailsFrame.Height = 10

    $resultsDetails = [Terminal.Gui.TextView]::new()

    $resultsDetails.X = 0
    $resultsDetails.Y = 0
    $resultsDetails.Width =
        [Terminal.Gui.Dim]::Fill()

    $resultsDetails.Height =
        [Terminal.Gui.Dim]::Fill()

    $resultsDetails.ReadOnly = $true
    $resultsDetails.WordWrap = $false

    $detailsFrame.Add($resultsDetails)

    $resultsPanel.Add($resultsSummaryFrame)
    $resultsPanel.Add($tableFrame)
    $resultsPanel.Add($detailsFrame)

    $script:Ui.ResultsPanel = $resultsPanel
    $script:Ui.ResultsSummary = $resultsSummary
    $script:Ui.ResultsTable = $resultsTable
    $script:Ui.ResultsDetails = $resultsDetails
    $script:Ui.ExportPathField = $exportPathField

    $window.Add($resultsPanel)

    # -------------------------------------------------------------------------
    # Bottom status bar area
    # -------------------------------------------------------------------------

    $statusFrame = [Terminal.Gui.FrameView]::new(
        'Status'
    )

    $statusFrame.X = 0
    $statusFrame.Y =
        [Terminal.Gui.Pos]::AnchorEnd(3)

    $statusFrame.Width =
        [Terminal.Gui.Dim]::Fill()

    $statusFrame.Height = 3

    $statusLabel = [Terminal.Gui.Label]::new(
        'Ready.'
    )

    $statusLabel.X = 1
    $statusLabel.Y = 0
    $statusLabel.Width =
        [Terminal.Gui.Dim]::Fill(30)

    $newButton = [Terminal.Gui.Button]::new(
        '_New'
    )

    $newButton.X =
        [Terminal.Gui.Pos]::AnchorEnd(27)

    $newButton.Y = 0

    $quitButton = [Terminal.Gui.Button]::new(
        '_Quit'
    )

    $quitButton.X =
        [Terminal.Gui.Pos]::AnchorEnd(14)

    $quitButton.Y = 0

    $newButton.add_Clicked(
        [System.Action]{
            Reset-Application
        }
    )

    $quitButton.add_Clicked(
        [System.Action]{
            Request-ApplicationExit
        }
    )

    $statusFrame.Add($statusLabel)
    $statusFrame.Add($newButton)
    $statusFrame.Add($quitButton)

    $script:Ui.StatusFrame = $statusFrame
    $script:Ui.StatusLabel = $statusLabel

    $window.Add($statusFrame)

    # -------------------------------------------------------------------------
    # Navigation events
    # -------------------------------------------------------------------------

    $navList.add_SelectedItemChanged(
        {
            $index = $script:Ui.NavList.SelectedItem

            if ($index -ge 0 -and $index -le 3) {
                Show-Panel -Index $index
            }
        }
    )

    $navList.add_OpenSelectedItem(
        {
            $index = $script:Ui.NavList.SelectedItem

            if ($index -ge 0 -and $index -le 3) {
                Show-Panel -Index $index
            }
        }
    )

    # Initial render
    Update-ResultsUi
    Update-ScanSummary
    Show-Panel -Index 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

try {
    Import-TerminalGui

    $script:State = New-AppState

    Initialize-TerminalUi

    [Terminal.Gui.Application]::Run()
}
catch {
    try {
        [Terminal.Gui.Application]::Shutdown()
    }
    catch {}

    Write-Error "Application error: $($_.Exception.Message)"
}
finally {
    try {
        [Terminal.Gui.Application]::Shutdown()
    }
    catch {}
}