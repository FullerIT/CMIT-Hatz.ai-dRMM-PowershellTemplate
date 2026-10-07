<#
Script: CMIT-dRMM-Mon-SupportID.ps1
Author: pellis@cmitsolutions.com
Version: 2026.02.05.001

Exit 0 = OK
Exit 1 = Needs remediation

#>

function Write-DRMMDiag {
    param([string[]]$Messages)

    Write-Output '<-Start Diagnostic->'
    foreach ($m in $Messages) { Write-Output $m }
    Write-Output '<-End Diagnostic->'
}

function Write-DRMMResult {
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


##### Example of when site variables or component level variables might be needed, component overrides site when set
if (($env:variable1SITE -as [string]).Length -gt 10) {
    $varSerial=$env:variable1SITE
    write-host "- Using Site-level serial key"
} 

if (($env:variable1 -as [string]).Length -gt 10) {
    if ($varSerial) {
        write-host "- Serial key overridden with value from Component-level serial key"
    } else {
        write-host "- Using Component-level serial key"
    }
    $varSerial=$env:variable1
}