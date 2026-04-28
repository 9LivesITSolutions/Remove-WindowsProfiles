#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes Windows user profiles with granular exclusion control.
    Supports local execution, single remote machine (WinRM/DCOM), and bulk
    multi-machine deployment with parallel WinRM sessions.

.DESCRIPTION
    Single-machine mode (default, or -ComputerName with one target):
      Runs a 3-phase pipeline in the current session:
        Phase 1 -- Build exclusion HashSet via Win32_UserAccount (once, O(1) lookup)
        Phase 2 -- Load Win32_UserProfile via CIM
        Phase 3 -- Classify and remove candidates

      Local execution: no CimSession opened (Get-CimInstance without session).
      Remote execution: CimSession opened with DCOM (PS5.1) or WSMan (PS7).
      Account detection is entirely SID-based -- locale-independent.

    Multi-machine mode (-Target with 2+ targets, or -TargetList):
      Opens parallel PSessions (WinRM), copies itself to each target,
      executes remotely, collects results, writes per-machine logs and CSV.

.PARAMETER ComputerName
    One or more target hostnames or IP addresses.
    One target    : single-machine mode (local or remote via CIM).
    Two or more   : multi-machine WinRM mode with parallel sessions.
    Default       : local machine.

.PARAMETER TargetList
    Path to a plain-text file, one hostname per line.
    Lines starting with # are ignored. Activates multi-machine mode.

.PARAMETER Exclude
    Exact SID strings and/or name wildcard patterns to exclude.
    Examples: -Exclude "svc_*"
              -Exclude "S-1-5-21-111-222-333-1001","backup_agent"

.PARAMETER Username
    Restrict removal to one or more specific account names or SIDs.
    Wildcards accepted (e.g. "john*", "S-1-5-21-...-1105").
    When specified, only matching profiles are candidates -- all others are skipped.
    Combine with -All to remove without confirmation, or -WhatIf to preview.
    Examples: -Username "jdoe"
              -Username "jdoe","jsmith"
              -Username "S-1-5-21-111-222-333-1105"

.PARAMETER All
    Remove all candidate profiles without per-profile confirmation.
    Required for unattended/multi-machine runs.

.PARAMETER WhatIf
    Simulate removals without deleting anything (manual switch, no ShouldProcess propagation).

.PARAMETER Credential
    PSCredential for remote sessions. If omitted, Kerberos pass-through is used.

.PARAMETER ThrottleLimit
    Maximum simultaneous WinRM sessions (multi-machine mode). Default: 10.

.PARAMETER LogPath
    Directory for per-machine logs and CSV report (multi-machine mode).
    Created automatically if absent. Default: .\Logs

.PARAMETER RemoteTempPath
    Temp directory on remote machines where the script is staged.
    Default: C:\Windows\Temp

.EXAMPLE
    # Local dry-run
    .\Remove-WindowsProfiles.ps1 -WhatIf

.EXAMPLE
    # Remove a single specific profile (local)
    .\Remove-WindowsProfiles.ps1 -Username "jdoe" -All

.EXAMPLE
    # Preview removal of a specific profile on a remote machine
    .\Remove-WindowsProfiles.ps1 -ComputerName "RDHPRD06" -Username "jdoe" -WhatIf

.EXAMPLE
    # Local interactive, exclude a pattern
    .\Remove-WindowsProfiles.ps1 -Exclude "svc_*"

.EXAMPLE
    # Single remote machine
    .\Remove-WindowsProfiles.ps1 -ComputerName "RDHPRD06" -All -Exclude "svc_*" -WhatIf

.EXAMPLE
    # Multi-machine inline
    .\Remove-WindowsProfiles.ps1 -ComputerName "PC-001","PC-002","PC-003" -All

.EXAMPLE
    # Multi-machine from file with credentials
    .\Remove-WindowsProfiles.ps1 -TargetList ".\targets.txt" -All `
        -Exclude "svc_*" -Credential (Get-Credential) -ThrottleLimit 5

.NOTES
    Author  : 9 Lives IT Solutions
    Version : 3.9
    Requires: PowerShell 5.1+ or 7+, local or remote Administrator rights

    WinRM quick-enable on targets (run as admin or deploy via GPO):
        Enable-PSRemoting -Force

    Well-known SID reference:
    https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-security-identifiers
#>

[CmdletBinding(DefaultParameterSetName = 'Inline')]
param (
    [Parameter(ParameterSetName = 'Inline')]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [Parameter(ParameterSetName = 'File', Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$TargetList,

    [Parameter()]
    [string[]]$Exclude = @(),

    [Parameter(HelpMessage = "Restrict removal to these specific account names or SIDs (wildcards accepted). Overrides -All for non-matching profiles.")]
    [string[]]$Username = @(),

    [Parameter()]
    [switch]$All,

    [Parameter()]
    [switch]$WhatIf,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [ValidateRange(1, 50)]
    [int]$ThrottleLimit = 10,

    [Parameter()]
    [string]$LogPath = (Join-Path $PSScriptRoot 'Logs'),

    [Parameter()]
    [string]$RemoteTempPath = 'C:\Windows\Temp'
)

# =============================================================================
# STATIC DEFINITIONS -- evaluated once at startup
# =============================================================================

#region Well-known SID sets

# Fixed NT AUTHORITY SIDs
$SID_EXACT_SYSTEM = [System.Collections.Generic.HashSet[string]]([StringComparer]::OrdinalIgnoreCase)
@(
    'S-1-5-18',   # NT AUTHORITY\SYSTEM        (LocalSystem)
    'S-1-5-19',   # NT AUTHORITY\LOCAL SERVICE
    'S-1-5-20',   # NT AUTHORITY\NETWORK SERVICE
    'S-1-5-17',   # NT AUTHORITY\IUSR          (IIS anonymous)
    'S-1-2-0',    # NULL AUTHORITY\LOCAL        (console logon)
    'S-1-3-0',    # CREATOR OWNER
    'S-1-3-1'     # CREATOR GROUP
) | ForEach-Object { $null = $SID_EXACT_SYSTEM.Add($_) }

# Variable sub-authority families -- matched by prefix
$SID_PREFIX_SYSTEM = @(
    'S-1-5-80-',   # NT SERVICE\*
    'S-1-5-82-',   # IIS APPPOOL\*
    'S-1-5-83-',   # NT VIRTUAL MACHINE\*
    'S-1-5-90-',   # Window Manager\* (DWM-n)
    'S-1-5-96-'    # Font Driver Host\* / containers
)

# Built-in local account RIDs (locale-independent)
# 500=Administrator, 501=Guest, 503=DefaultAccount, 504=WDAGUtilityAccount
$SID_RID_BUILTIN = [System.Collections.Generic.HashSet[string]]([StringComparer]::Ordinal)
@('500', '501', '503', '504') | ForEach-Object { $null = $SID_RID_BUILTIN.Add($_) }

$RID_REGEX = [regex]'^S-1-5-21-\d+-\d+-\d+-(\d+)$'

#endregion

# =============================================================================
# COMPAT LAYER -- Get-CimInstance (PS5.1+) + WinRM CimSession
# =============================================================================

function Test-IsLocalTarget {
    # Returns $true when the target resolves to the local machine.
    # Case-insensitive; covers hostname, localhost, 127.0.0.1, dot.
    param([string]$Target)
    $aliases = @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '::1', '.')
    foreach ($a in $aliases) { if ($a -ieq $Target) { return $true } }
    return $false
}

function New-CompatCimSession {
    param([string]$TargetComputer)
    $p = @{ ComputerName = $TargetComputer; ErrorAction = 'Stop' }
    if ($Credential) { $p['Credential'] = $Credential }
    return New-CimSession @p
}

function Get-CimData {
    # Thin wrapper: Get-CimInstance, local or via CimSession.
    param(
        [string]$ClassName,
        [string]$Filter,
        [object]$Session   # Microsoft.Management.Infrastructure.CimSession or $null
    )
    $p = @{ ClassName = $ClassName }
    if ($Filter)  { $p['Filter']     = $Filter }
    if ($Session) { $p['CimSession'] = $Session }
    return Get-CimInstance @p
}

function Remove-CimProfile {
    # Deletes a Win32_UserProfile instance via Remove-CimInstance.
    # Win32_UserProfile does NOT expose a Delete() WMI method -- the correct
    # approach is Remove-CimInstance which issues a CIM DeleteInstance operation.
    # Works on PS5.1 and PS7, local and remote (via CimSession).
    param([object]$ProfileInstance, [object]$Session)
    $p = @{ InputObject = $ProfileInstance; ErrorAction = 'Stop' }
    if ($Session) { $p['CimSession'] = $Session }
    Remove-CimInstance @p
}

# =============================================================================
# SHARED FUNCTIONS
# =============================================================================

function Write-Banner {
    param([string]$Subtitle)
    $line = '-' * 72
    Write-Host "`n$line" -ForegroundColor DarkGray
    Write-Host "  REMOVE-WINDOWSPROFILES v3.9  |  $Subtitle  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host "$line`n" -ForegroundColor DarkGray
}

function Build-ExcludedSIDSet {
    # Builds the SID exclusion HashSet. Called ONCE before the profile loop.
    param([string]$TargetComputer, [object]$Session)

    $set = [System.Collections.Generic.HashSet[string]]([StringComparer]::OrdinalIgnoreCase)

    # A. Fixed well-known NT AUTHORITY SIDs
    foreach ($sid in $SID_EXACT_SYSTEM) { $null = $set.Add($sid) }

    # B. Built-in local accounts resolved by RID via Win32_UserAccount
    try {
        $accounts = Get-CimData -ClassName 'Win32_UserAccount' `
            -Filter 'LocalAccount=True AND SIDType=1' -Session $Session
        foreach ($acct in $accounts) {
            $m = $RID_REGEX.Match($acct.SID)
            if ($m.Success -and $SID_RID_BUILTIN.Contains($m.Groups[1].Value)) {
                $null = $set.Add($acct.SID)
                Write-Verbose "  [PRE] Built-in detected: $($acct.Name) ($($acct.SID))"
            }
        }
    }
    catch {
        Write-Warning "Could not query Win32_UserAccount on '$TargetComputer': $_"
        Write-Warning "Built-in accounts will fall back to RID detection in the classification phase."
    }

    # C. Explicit SIDs from -Exclude
    foreach ($entry in $script:Exclude) {
        if ($entry -match '^S-1-') {
            $null = $set.Add($entry)
            Write-Verbose "  [PRE] Explicit SID exclusion: $entry"
        }
    }

    Write-Verbose "  [PRE] HashSet ready: $($set.Count) SID(s)"
    return $set
}

function Test-ExcludedByName {
    param([string]$AccountName)
    foreach ($pattern in $script:NamePatterns) {
        if ($AccountName -like $pattern) { return $true }
    }
    return $false
}

function Resolve-AccountName {
    param([string]$SID)
    try {
        $o = New-Object System.Security.Principal.SecurityIdentifier($SID)
        return ($o.Translate([System.Security.Principal.NTAccount]).Value -split '\\')[-1]
    }
    catch { return $null }
}

function Test-IsSystemByPrefix {
    param([string]$SID)
    foreach ($prefix in $SID_PREFIX_SYSTEM) {
        if ($SID.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $m = $RID_REGEX.Match($SID)
    if ($m.Success -and $SID_RID_BUILTIN.Contains($m.Groups[1].Value)) { return $true }
    return $false
}

# =============================================================================
# SINGLE-MACHINE CORE
# =============================================================================

function Invoke-LocalProfileCleanup {
    param([string]$TargetComputer)

    $result = [PSCustomObject]@{
        ComputerName = $TargetComputer
        Status = 'Unknown'; Removed = 0; Failed = 0; Skipped = 0; Error = $null; Output = $null
    }

    $outputLines = [System.Collections.Generic.List[string]]::new()
    function Write-Log {
        param([string]$Msg, [string]$Color = 'White')
        Write-Host $Msg -ForegroundColor $Color
        $outputLines.Add($Msg)
    }

    # Open CimSession only for genuine remote targets
    $isLocal    = Test-IsLocalTarget -Target $TargetComputer
    $cimSession = $null
    if (-not $isLocal) {
        try {
            $cimSession = New-CompatCimSession -TargetComputer $TargetComputer
        }
        catch {
            $result.Status = 'Error'
            $result.Error  = "CimSession failed: $_"
            Write-Host "[ERROR] Cannot connect to '$TargetComputer': $_" -ForegroundColor Red
            return $result
        }
    }

    try {
        # -- Phase 1: build exclusion set -----------------------------------------
        Write-Log '[1/3] Building exclusion set...' 'DarkGray'
        $ExcludedSIDs = Build-ExcludedSIDSet -TargetComputer $TargetComputer -Session $cimSession
        Write-Log "      $($ExcludedSIDs.Count) SID(s) pre-excluded (system + built-in + explicit)" 'DarkGray'

        # -- Phase 2: load profiles -----------------------------------------------
        Write-Log '[2/3] Loading Win32_UserProfile...' 'DarkGray'
        $allProfiles = @(Get-CimData -ClassName 'Win32_UserProfile' -Session $cimSession)
        Write-Log "      $($allProfiles.Count) profile(s) found" 'DarkGray'

        # -- Phase 3: classify ----------------------------------------------------
        Write-Log '[3/3] Classifying profiles...' 'DarkGray'

        $enriched = foreach ($p in $allProfiles) {

            # O(1) HashSet lookup
            if ($p.Special -or $ExcludedSIDs.Contains($p.SID)) {
                [PSCustomObject]@{ Profile=$p; SID=$p.SID; AccountName=$p.SID
                    LocalPath=$p.LocalPath; Status='SYSTEM'; IsSystem=$true; IsExcluded=$false; Loaded=$false }
                continue
            }

            # Safety net for service/virtual account families
            if (Test-IsSystemByPrefix -SID $p.SID) {
                [PSCustomObject]@{ Profile=$p; SID=$p.SID; AccountName=$p.SID
                    LocalPath=$p.LocalPath; Status='SYSTEM (prefix)'; IsSystem=$true; IsExcluded=$false; Loaded=$false }
                continue
            }

            # Real user profile
            $name        = Resolve-AccountName -SID $p.SID
            $displayName = if ($name) { $name } else { "<orphan: $($p.SID)>" }
            $excluded    = ($script:NamePatterns.Count -gt 0) -and (Test-ExcludedByName -AccountName $displayName)
            $status      = if ($p.Loaded) { 'LOADED (active session)' } `
                           elseif ($excluded) { 'EXCLUDED (parameter)' } `
                           else { 'Removable' }

            [PSCustomObject]@{ Profile=$p; SID=$p.SID; AccountName=$displayName
                LocalPath=$p.LocalPath; Status=$status; IsSystem=$false; IsExcluded=$excluded; Loaded=[bool]$p.Loaded }
        }

        Write-Log ''

        # Inventory table
        Write-Log '=== PROFILE INVENTORY ===' 'Yellow'
        $enriched | Sort-Object IsSystem, AccountName | Format-Table -AutoSize `
            @{N='Account'; E={ $_.AccountName }; Width=32 },
            @{N='Path';    E={ $_.LocalPath };   Width=40 },
            @{N='Status';  E={ $_.Status };      Width=24 },
            @{N='SID';     E={ $_.SID } } | Out-String | ForEach-Object { Write-Log $_ }

        # Candidate selection
        $candidates = @($enriched | Where-Object { -not $_.IsSystem -and -not $_.IsExcluded -and -not $_.Loaded })
        $loaded     = @($enriched | Where-Object { -not $_.IsSystem -and $_.Loaded })

        # Username filter: if specified, restrict candidates to matching accounts/SIDs only
        if ($script:Username.Count -gt 0) {
            $candidates = @($candidates | Where-Object {
                $item = $_
                $script:Username | Where-Object {
                    $item.AccountName -like $_ -or $item.SID -eq $_
                }
            })
            if ($candidates.Count -eq 0) {
                Write-Log "No profile matched -Username filter: $($script:Username -join ', ')" 'Yellow'
                $result.Status = 'Success'
                $result.Output = $outputLines -join "`n"
                return $result
            }
            Write-Log "Username filter active: $($script:Username -join ', ') -- $($candidates.Count) match(es)" 'DarkCyan'
        }

        if ($loaded.Count -gt 0) {
            Write-Log "[WARNING] $($loaded.Count) profile(s) with an active session -- skipped:" 'Yellow'
            $loaded | ForEach-Object { Write-Log "  - $($_.AccountName)  [$($_.LocalPath)]" 'Yellow' }
            Write-Log ''
        }

        if ($candidates.Count -eq 0) {
            Write-Log 'No profiles to remove after filtering.' 'Green'
            $result.Status = 'Success'
            $result.Output = $outputLines -join "`n"
            return $result
        }

        Write-Log "=== REMOVAL CANDIDATES ($($candidates.Count)) ===" 'Cyan'
        $candidates | ForEach-Object { Write-Log "  - $($_.AccountName)  [$($_.LocalPath)]" 'White' }
        Write-Log ''

        if ($WhatIf) {
            Write-Log 'WhatIf mode -- no profiles will be removed' 'DarkCyan'
        } elseif (-not $All) {
            Write-Log 'Interactive mode -- use -All to remove without per-profile confirmation' 'DarkGray'
        }

        # Removal loop
        $countOK = $countKO = $countSkip = 0

        # WhatIf: list candidates and exit -- no prompts, no deletions
        if ($WhatIf) {
            foreach ($item in $candidates) {
                $label = "$($item.AccountName)  [$($item.LocalPath)]"
                Write-Log "  [WIF] WhatIf  : $label" 'DarkCyan'
                $countSkip++
            }
        }
        elseif ($All) {
            foreach ($item in $candidates) {
                $label = "$($item.AccountName)  [$($item.LocalPath)]"
                try {
                    Remove-CimProfile -ProfileInstance $item.Profile -Session $cimSession
                    Write-Log "  [OK]  Removed : $label" 'Green'; $countOK++
                }
                catch { Write-Log "  [ERR] Failed  : $label`n        $_" 'Red'; $countKO++ }
            }
        }
        else {
            foreach ($item in $candidates) {
                $label = "$($item.AccountName)  [$($item.LocalPath)]"
                $choice = $Host.UI.PromptForChoice(
                    'Remove this profile?', "  $label",
                    @(
                        [System.Management.Automation.Host.ChoiceDescription]::new('&Yes',  'Remove this profile'),
                        [System.Management.Automation.Host.ChoiceDescription]::new('&No',   'Skip this profile'),
                        [System.Management.Automation.Host.ChoiceDescription]::new('&Quit', 'Stop the script')
                    ), 1
                )
                switch ($choice) {
                    0 {
                        try {
                            Remove-CimProfile -ProfileInstance $item.Profile -Session $cimSession
                            Write-Log "  [OK]  Removed : $label" 'Green'; $countOK++
                        }
                        catch { Write-Log "  [ERR] Failed  : $label`n        $_" 'Red'; $countKO++ }
                    }
                    1 { Write-Log "  [SKP] Skipped : $label" 'DarkGray'; $countSkip++ }
                    2 { Write-Log 'Script stopped by user.' 'Yellow'; break }
                }
            }
        }

        # Per-machine summary
        $line = '-' * 72
        Write-Log $line 'DarkGray'
        Write-Log "  SUMMARY  |  Removed: $countOK  |  Failed: $countKO  |  Skipped/WhatIf: $countSkip" 'Cyan'
        Write-Log $line 'DarkGray'

        $result.Removed = $countOK
        $result.Failed  = $countKO
        $result.Skipped = $countSkip
        $result.Status  = if ($countKO -gt 0) { 'PartialFailure' } else { 'Success' }
    }
    catch {
        $result.Status = 'Error'
        $result.Error  = $_.Exception.Message
        Write-Log "[ERROR] $($_.Exception.Message)" 'Red'
    }
    finally {
        if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
    }

    $result.Output = $outputLines -join "`n"
    return $result
}

# =============================================================================
# MULTI-MACHINE ORCHESTRATOR (WinRM parallel sessions)
# =============================================================================

function Invoke-MultiMachineCleanup {
    param([string[]]$Targets)

    if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }

    $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $selfPath   = $MyInvocation.ScriptName
    $report     = [System.Collections.Generic.List[PSCustomObject]]::new()
    $machineIdx = 0

    Write-Host "Log path    : $LogPath" -ForegroundColor DarkGray
    Write-Host "Throttle    : $ThrottleLimit parallel sessions" -ForegroundColor DarkGray
    Write-Host "Mode        : $(if ($All) { 'Bulk (-All)' } else { 'Interactive' })$(if ($WhatIf) { ' + WhatIf' })" -ForegroundColor DarkGray
    Write-Host "Exclude     : $(if ($Exclude) { $Exclude -join ', ' } else { '(none)' })`n" -ForegroundColor DarkGray

    $remoteBlock = {
        param([string]$ScriptDest, [string[]]$Exclude, [string[]]$Username, [bool]$All, [bool]$WhatIfActive)
        $result = [PSCustomObject]@{
            ComputerName=$env:COMPUTERNAME; Status='Unknown'
            Removed=0; Failed=0; Skipped=0; Error=$null; Output=$null
        }
        try {
            if (-not (Test-Path $ScriptDest)) { throw "Script not found at $ScriptDest" }
            $args = @()
            if ($All)         { $args += '-All' }
            if ($WhatIfActive){ $args += '-WhatIf' }
            if ($Exclude)     { $args += '-Exclude';  $args += $Exclude }
            if ($Username)    { $args += '-Username'; $args += $Username }
            $output = & $ScriptDest @args *>&1 | Out-String
            if ($output -match 'Removed:\s*(\d+)')     { $result.Removed = [int]$Matches[1] }
            if ($output -match 'Failed:\s*(\d+)')       { $result.Failed  = [int]$Matches[1] }
            if ($output -match 'Skipped[^:]*:\s*(\d+)') { $result.Skipped = [int]$Matches[1] }
            $result.Status = if ($result.Failed -gt 0) { 'PartialFailure' } else { 'Success' }
            $result.Output = $output
        }
        catch { $result.Status = 'Error'; $result.Error = $_.Exception.Message }
        return $result
    }

    for ($i = 0; $i -lt $Targets.Count; $i += $ThrottleLimit) {
        $batch = $Targets[$i .. [Math]::Min($i + $ThrottleLimit - 1, $Targets.Count - 1)]
        Write-Host "Opening sessions: $($batch -join ', ')" -ForegroundColor DarkGray

        $sessionParams = @{ ComputerName = $batch; ErrorAction = 'SilentlyContinue' }
        if ($Credential) { $sessionParams['Credential'] = $Credential }
        $sessions = New-PSSession @sessionParams

        $connected = @($sessions | Select-Object -ExpandProperty ComputerName)
        foreach ($dead in ($batch | Where-Object { $connected -notcontains $_ })) {
            $machineIdx++
            $report.Add([PSCustomObject]@{
                '#'=$machineIdx; ComputerName=$dead; Status='Unreachable'
                Removed='-'; Failed='-'; Skipped='-'; Error='PSSession failed'
            })
            Write-Host "  [$machineIdx/$($Targets.Count)] $dead -- UNREACHABLE" -ForegroundColor Red
        }

        if (-not $sessions) { continue }

        $remoteDest = Join-Path $RemoteTempPath (Split-Path $selfPath -Leaf)
        foreach ($session in $sessions) {
            try { Copy-Item -Path $selfPath -Destination $RemoteTempPath -ToSession $session -Force }
            catch { Write-Warning "Copy failed to $($session.ComputerName): $_" }
        }

        $results = Invoke-Command -Session $sessions -ScriptBlock $remoteBlock `
            -ArgumentList $remoteDest, $Exclude, $Username, ([bool]$All), ([bool]$WhatIf) `
            -ErrorAction SilentlyContinue

        foreach ($r in $results) {
            $machineIdx++
            $r.Output | Out-File -FilePath (Join-Path $LogPath "$($r.ComputerName)_$timestamp.log") -Encoding UTF8 -Force
            $color = switch ($r.Status) { 'Success' { 'Green' } 'PartialFailure' { 'Yellow' } default { 'Red' } }
            Write-Host "  [$machineIdx/$($Targets.Count)] $($r.ComputerName) -- $($r.Status)  (removed: $($r.Removed)  failed: $($r.Failed)  skipped: $($r.Skipped))" -ForegroundColor $color
            $report.Add([PSCustomObject]@{
                '#'=$machineIdx; ComputerName=$r.ComputerName; Status=$r.Status
                Removed=$r.Removed; Failed=$r.Failed; Skipped=$r.Skipped; Error=$r.Error
            })
        }

        Invoke-Command -Session $sessions -ScriptBlock {
            param($p) Remove-Item -Path $p -Force -ErrorAction SilentlyContinue
        } -ArgumentList $remoteDest
        $sessions | Remove-PSSession
        Write-Host ''
    }

    # Consolidated report
    $csvPath = Join-Path $LogPath "report_$timestamp.csv"
    $report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    $line = '-' * 72
    Write-Host $line -ForegroundColor DarkGray
    Write-Host '  CONSOLIDATED SUMMARY' -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkGray

    $report | Format-Table -AutoSize `
        @{N='#';        E={ $_.'#' };          Width=4  },
        @{N='Computer'; E={ $_.ComputerName }; Width=24 },
        @{N='Status';   E={ $_.Status };       Width=16 },
        @{N='Removed';  E={ $_.Removed };      Width=9  },
        @{N='Failed';   E={ $_.Failed };        Width=8  },
        @{N='Skipped';  E={ $_.Skipped };      Width=9  },
        @{N='Error';    E={ $_.Error };         Width=40 }

    $totalRemoved = ($report | Where-Object { $_.Removed -match '^\d+$' } |
                    Measure-Object -Property Removed -Sum).Sum
    $totalFailed  = ($report | Where-Object { $_.Failed  -match '^\d+$' } |
                    Measure-Object -Property Failed  -Sum).Sum
    $countOK      = @($report | Where-Object { $_.Status -eq 'Success' }).Count
    $countPartial = @($report | Where-Object { $_.Status -eq 'PartialFailure' }).Count
    $countErr     = @($report | Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'Unreachable' }).Count

    Write-Host "  Machines : $($Targets.Count) targeted  |  $countOK success  |  $countPartial partial  |  $countErr error/unreachable" -ForegroundColor Cyan
    Write-Host "  Profiles : $totalRemoved removed  |  $totalFailed failed" -ForegroundColor Cyan
    Write-Host "  Report   : $csvPath" -ForegroundColor Cyan
    Write-Host "$line`n" -ForegroundColor DarkGray
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Pre-compute name-pattern exclusions once (before $targets resolution)
$script:NamePatterns = @($Exclude | Where-Object { $_ -notmatch '^S-1-' })
$script:Exclude      = @($Exclude)
$script:Username     = @($Username)

# Resolve target list - always a [string[]] via @()
[string[]]$targets = if ($PSCmdlet.ParameterSetName -eq 'File') {
    @(Get-Content $TargetList |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' } |
        ForEach-Object { $_.Trim() })
} else {
    @($ComputerName)
}

if ($targets.Count -eq 0) { Write-Error 'No valid targets found.'; exit 1 }

# Route: single-machine vs multi-machine
[string]$firstTarget = $targets[0]
if ($targets.Count -eq 1) {
    Write-Banner -Subtitle $firstTarget
    Invoke-LocalProfileCleanup -TargetComputer $firstTarget | Out-Null
}
else {
    Write-Banner -Subtitle "$($targets.Count) targets -- WinRM mode"
    Invoke-MultiMachineCleanup -Targets $targets
}