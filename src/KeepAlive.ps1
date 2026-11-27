<#
================================================================================
 MODULE: KeepAlive.ps1
 - Prevents Windows lock/sleep during monitoring shifts
 - Dual-Engine: Win32 SetThreadExecutionState with WScript F15 virtual key fallback
================================================================================
#>

$global:keepAliveActive = $false
$global:keepAliveEngine = ""
$global:wscriptShell = $null

function Initialize-KeepAlive {
    if (-not ([System.Management.Automation.PSTypeName]'Win32.Kernel32').Type) {
        try {
            Add-Type -MemberDefinition @"
[DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
"@ -Name "Kernel32" -Namespace "Win32" -ErrorAction Stop
        } catch {}
    }

    if (([System.Management.Automation.PSTypeName]'Win32.Kernel32').Type) {
        try {
            [void][Win32.Kernel32]::SetThreadExecutionState(0x80000003)
            $global:keepAliveActive = $true
            $global:keepAliveEngine = "API"
            return
        } catch {}
    }

    try {
        $global:wscriptShell = New-Object -ComObject WScript.Shell
        $global:keepAliveActive = $true
        $global:keepAliveEngine = "F15"
    } catch {}
}

function Send-KeepAliveHeartbeat {
    if ($global:keepAliveEngine -eq "F15" -and $null -ne $global:wscriptShell) {
        try { $global:wscriptShell.SendKeys("{F15}") } catch {}
    }
}

function Restore-KeepAlive {
    if ($global:keepAliveActive -and $global:keepAliveEngine -eq "API") {
        try { [void][Win32.Kernel32]::SetThreadExecutionState(0x80000000) } catch {}
    }
    if ($null -ne $global:wscriptShell) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($global:wscriptShell) | Out-Null } catch {}
    }
}
