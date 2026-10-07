<#
Script:        CMIT-dRMM-Template.ps1
Author:        pellis@cmitsolutions.com
Version:       2026.10.07.001
Last Modified: 2026-10-07
Description:   Base template for Datto RMM Monitor scripts. Provides result/diagnostic
               output, site/component variable resolution, and UDF writing.

Exit 0 = OK
Exit 1 = Alert (needs remediation)

Change Log:
  2026.10.07.001 - Merged original monitor template (Write-DRMMDiag, Write-DRMMResult)
                   with Write-DattoUDF; converted site/component variable example
                   into reusable Get-DRMMVariable function.

Component variables (define only the ones a given script uses):
  usrUDF (String) - UDF number 1-300 to write a summary to; blank to skip.
#>

#region Functions ----------------------------------------------------------------------

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

function Get-DRMMVariable {
    # Resolves a variable with site-level fallback. Component value wins when set.
    # Convention: site variable is named <Name>SITE (e.g. variable1SITE).
    # -MinLength lets you ignore junk/short values (e.g. a serial key must be > 10 chars).
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$MinLength = 1
    )

    $varSite      = [Environment]::GetEnvironmentVariable("${Name}SITE") -as [string]
    $varComponent = [Environment]::GetEnvironmentVariable($Name) -as [string]
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
        [Parameter(Mandatory)][string]$Value,
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

#endregion

#region Usage reference ----------------------------------------------------------------
# Typical monitor flow:
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
#       Write-DRMMResult -ExitCode 1 -Message $varSummary -Diag $varDiag
#   } else {
#       Write-DRMMResult -ExitCode 0 -Message $varSummary
#   }
#endregion
