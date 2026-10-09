<#
Script:        CMIT-dRMM-Template.ps1
Author:        pellis@cmitsolutions.com
Version:       2026.10.08.003
Last Modified: 2026-10-08
Description:   Base template for Datto RMM Monitor and Script (Job) components.
               Provides monitor result/diagnostic output, script exit handling,
               site/component variable resolution, UDF writing, and writing to the
               local "Datto" Windows event log.

Component types and naming (<Verb-Noun> uses approved PowerShell verbs):
  Monitor     - CMIT-dRMM-Mon-<Verb-Noun>.ps1. Ends with Write-DRMMResult.
                Exit 0 = OK, Exit 1 = Alert.
  Remediation - CMIT-dRMM-Rem-<Verb-Noun>.ps1. Script paired with a Monitor.
                Ends with Exit-DRMMScript. Exit 0 = Success, Exit 1 = Failed.
  Script      - CMIT-dRMM-<Verb-Noun>.ps1. Ends with Exit-DRMMScript.
                Exit 0 = Success, Exit 1 = Failed.

Generated scripts include only the functions they call (plus dependencies).

Change Log:
  2026.10.08.003 - Header updated for Mon-/Rem-/Verb-Noun naming and the
                   include-only-used-functions rule. No code changes.
  2026.10.08.002 - Added Exit-DRMMScript for Script (Job) components; split functions
                   into Shared / Monitor / Script regions. Get-DRMMVariable now trims
                   whitespace. Write-DattoUDF accepts an empty value (clears the UDF);
                   Write-DattoEvent skips empty messages instead of throwing.
  2026.10.08.001 - Added Initialize-DattoEventLog and Write-DattoEvent for logging to
                   the "Datto" event log (source "DRMM"). Log is created on first use.
  2026.10.07.001 - Merged original monitor template (Write-DRMMDiag, Write-DRMMResult)
                   with Write-DattoUDF; converted site/component variable example
                   into reusable Get-DRMMVariable function.

Component variables (define only the ones a given script uses):
  usrUDF (String) - UDF number 1-300 to write a summary to; blank to skip.

Requirements:
  Windows PowerShell 5.1 (the Datto RMM default). The *-EventLog cmdlets do not exist
  in PowerShell 7+. Creating the event log requires admin rights (the agent runs as
  SYSTEM, so this is normally satisfied).
#>

#region Monitor functions (Monitor components only) -------------------------------------

function Write-DRMMDiag {
    # Diagnostic block - shown in the monitor's alert detail, not the result line
    param([string[]]$Messages)

    Write-Output '<-Start Diagnostic->'
    foreach ($m in $Messages) { Write-Output $m }
    Write-Output '<-End Diagnostic->'
}

function Write-DRMMResult {
    # Emits diagnostic (optional) + result block, then EXITS the script.
    # Anything that must run (UDF writes, cleanup) has to happen before this call.
    param(
        [int]$ExitCode,
        [string]$Message,
        [string[]]$Diag = @()
    )

    if ($Diag.Count -gt 0) {
        Write-DRMMDiag -Messages $Diag
    }

    Write-Output '<-Start Result->'
    if ($ExitCode -eq 0) {
        Write-Output "OK=$Message"
    } else {
        Write-Output "Alert=$Message"
    }
    Write-Output '<-End Result->'

    exit $ExitCode
}

#endregion

#region Script functions (Script / Job components only) -------------------------------

function Exit-DRMMScript {
    # Writes optional detail lines and a final status line, then EXITS the script.
    # dRMM captures stdout in the job output; a non-zero exit flags the job as failed.
    # Anything that must run (UDF writes, event log, cleanup) has to happen before this call.
    param(
        [int]$ExitCode = 0,
        [string]$Message,
        [string[]]$Details = @()
    )

    foreach ($d in $Details) { Write-Output $d }

    if ($ExitCode -eq 0) {
        Write-Output "SUCCESS: $Message"
    } else {
        Write-Output "FAILED: $Message"
    }

    exit $ExitCode
}

#endregion

#region Shared functions (all component types) ----------------------------------------

function Get-DRMMVariable {
    # Resolves a variable with site-level fallback. Component value wins when set.
    # Convention: site variable is named <Name>SITE (e.g. variable1SITE).
    # -MinLength lets you ignore junk/short values (e.g. a serial key must be > 10 chars).
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$MinLength = 1
    )

    # [string] cast turns a missing variable into '' so .Trim()/.Length are always safe
    $varSite      = ([string][Environment]::GetEnvironmentVariable("${Name}SITE")).Trim()
    $varComponent = ([string][Environment]::GetEnvironmentVariable($Name)).Trim()
    $varValue     = $null

    if ($varSite.Length -ge $MinLength) {
        $varValue = $varSite
        write-host "- [$Name] Using Site-level value"
    }

    if ($varComponent.Length -ge $MinLength) {
        if ($varValue) {
            write-host "- [$Name] Site-level value overridden by Component-level value"
        } else {
            write-host "- [$Name] Using Component-level value"
        }
        $varValue = $varComponent
    }

    return $varValue
}

function Write-DattoUDF {
    # Writes a string to HKLM:\Software\CentraStage\Custom<N>.
    # The agent picks it up on its next audit, so the portal won't update instantly.
    param(
        # Empty string is allowed so a script can clear a stale UDF value
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [string]$UDF = $env:usrUDF,
        [string]$Prefix
    )

    if ($Prefix) {$Value = "$Prefix`: $Value"}

    # Datto RMM supports UDF 1-300
    $varMaxUDF = 300
    if ($UDF -notmatch '^\d+$' -or [int]$UDF -lt 1 -or [int]$UDF -gt $varMaxUDF) {
        write-host "- Not writing to UDF (no valid UDF number supplied):"
        write-host "  $Value"
        return
    }

    # UDF fields hold a maximum of 255 characters
    if ($Value.Length -gt 255) {
        write-host "! NOTICE: UDF value is $($Value.Length) characters; truncating to 255."
        $Value = $Value.Substring(0,255)
    }

    # Missing key means the agent isn't installed or healthy; don't create it
    if (!(test-path 'HKLM:\Software\CentraStage')) {
        write-host "! ERROR: HKLM:\Software\CentraStage not found. Is the Datto RMM agent installed?"
        return
    }

    try {
        New-ItemProperty -Path 'HKLM:\Software\CentraStage' -Name "Custom$UDF" -Value $Value -PropertyType String -Force -ea Stop | out-null
        write-host "- Wrote summary to UDF$UDF`:"
        write-host "  $Value"
    } catch {
        write-host "! ERROR: Failed to write UDF$UDF`: $($_.Exception.Message)"
    }
}

function Initialize-DattoEventLog {
    # Ensures the "Datto" event log and "DRMM" source exist. Safe to call every run:
    # if both already exist it does nothing. Returns $true when the log is ready to use.
    # Creating the log adds HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Datto and a
    # new .evtx file - a one-time, persistent change on the endpoint.
    param(
        [string]$LogName = 'Datto',
        [string]$Source  = 'DRMM',
        [long]$MaximumSize = 10MB
    )

    if ($script:DattoEventLogReady) { return $true }

    try {
        if ([System.Diagnostics.EventLog]::SourceExists($Source)) {
            # Source already registered - make sure it points at the expected log.
            # A source can only belong to one log; writing would otherwise land elsewhere.
            $varOwner = [System.Diagnostics.EventLog]::LogNameFromSourceName($Source, '.')
            if ($varOwner -ne $LogName) {
                write-host "! ERROR: Event source '$Source' is registered to the '$varOwner' log, not '$LogName'. Not writing events."
                return $false
            }
        } else {
            New-EventLog -LogName $LogName -Source $Source -ea Stop
            # The default size for a new classic log is small; raise it and let it wrap
            # so the log never stops accepting events when full.
            Limit-EventLog -LogName $LogName -MaximumSize $MaximumSize -OverflowAction OverwriteAsNeeded -ea SilentlyContinue
            Write-EventLog -LogName $LogName -Source $Source -EntryType Information -EventId 1 `
                -Message "$LogName event log created by the DRMM Agent" -ea Stop
            write-host "- Created '$LogName' event log with source '$Source'"
        }
        $script:DattoEventLogReady = $true
        return $true
    } catch {
        write-host "! ERROR: Unable to initialize '$LogName' event log: $($_.Exception.Message)"
        return $false
    }
}

function Write-DattoEvent {
    # Writes an entry to the "Datto" event log, creating the log on first use.
    # Failures are reported to stdout but never stop the monitor.
    # Event ID 1 is reserved for the "log created" entry.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Information','Warning','Error')][string]$EntryType = 'Information',
        [ValidateRange(0,65535)][int]$EventId = 2,
        [string]$LogName = 'Datto',
        [string]$Source  = 'DRMM'
    )

    if (!$Message) {
        write-host "! NOTICE: Empty event message; nothing written to '$LogName' log."
        return
    }

    if (!(Initialize-DattoEventLog -LogName $LogName -Source $Source)) { return }

    # Event messages max out around 31,839 characters
    if ($Message.Length -gt 31000) {
        write-host "! NOTICE: Event message is $($Message.Length) characters; truncating to 31000."
        $Message = $Message.Substring(0,31000)
    }

    try {
        Write-EventLog -LogName $LogName -Source $Source -EntryType $EntryType -EventId $EventId -Message $Message -ea Stop
        write-host "- Wrote $EntryType event $EventId to '$LogName' log"
    } catch {
        write-host "! ERROR: Failed to write event to '$LogName' log: $($_.Exception.Message)"
    }
}

#endregion

#region Usage reference ----------------------------------------------------------------
# Typical MONITOR flow:
#
#   $varSerial = Get-DRMMVariable -Name 'variable1' -MinLength 11
#   if (!$varSerial) {
#       Write-DRMMResult -ExitCode 1 -Message "No serial key supplied" `
#           -Diag @("Set variable1 at the component or variable1SITE at the site.")
#   }
#
#   # ...monitoring logic builds $varSummary, $varDiag, $varAlert...
#
#   Write-DattoUDF -Value $varSummary -Prefix "SupportID"   # before Write-DRMMResult
#
#   if ($varAlert) {
#       Write-DattoEvent -EntryType Warning -EventId 2 -Message $varSummary  # before Write-DRMMResult
#       Write-DRMMResult -ExitCode 1 -Message $varSummary -Diag $varDiag
#   } else {
#       Write-DRMMResult -ExitCode 0 -Message $varSummary
#   }
#
# Typical SCRIPT (Job) flow:
#
#   $varTarget = Get-DRMMVariable -Name 'usrTarget'
#   if (!$varTarget) { Exit-DRMMScript -ExitCode 1 -Message "usrTarget not supplied" }
#
#   # ...check current state; only change it if needed (keep it safe to re-run)...
#
#   try {
#       # ...make the change...
#       Write-DattoEvent -EntryType Information -EventId 10 -Message "Changed X on $env:COMPUTERNAME"
#       Exit-DRMMScript -ExitCode 0 -Message "X configured"
#   } catch {
#       Write-DattoEvent -EntryType Error -EventId 11 -Message "Failed to change X: $($_.Exception.Message)"
#       Exit-DRMMScript -ExitCode 1 -Message "X not configured: $($_.Exception.Message)"
#   }
#endregion
