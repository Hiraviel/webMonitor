<#
================================================================================
 PREVENTIVE PORTAL MONITOR - DAVITA IT (v4.1 NOC Database Edition)
 - CSV Database Storage (Auto-snapshot every 5 minutes to history.csv)
 - Persistent History: Restores counters across PC reboots/restarts
 - Outage & SLA Incident Logging (outages.log with Downtime Duration calculation)
 - Real-time Uptime SLA Percentage Column
 - Dual-Engine KeepAlive (API kernel32 + COM Fallback)
 - Brand Color Coding: DaVita Orange (DarkYellow) vs TCS Support (Cyan)
 - Hotkeys: [1] Interval   [2] Edit List   [3] Force Scan   [4] Outages   [5] Open CSV
================================================================================
#>

# 1. Native Windows KeepAlive (Dual Engine: API + Virtual Key Fallback)
$keepAliveActive = $false
$keepAliveEngine = ""
$wscriptShell = $null

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
        $keepAliveActive = $true
        $keepAliveEngine = "API"
    } catch {}
}

if (-not $keepAliveActive) {
    try {
        $wscriptShell = New-Object -ComObject WScript.Shell
        $keepAliveActive = $true
        $keepAliveEngine = "F15"
    } catch {}
}

# 2. Configuración de Consola y Seguridad TLS
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
[System.Net.ServicePointManager]::Expect100Continue = $false

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptDir "portales.txt"
$logFile = Join-Path $scriptDir "outages.log"
$csvDbFile = Join-Path $scriptDir "history.csv"

$intervalSeconds = 120 # Escaneo de portales cada 120s
$csvSnapshotIntervalSec = 300 # Guardado en DB cada 5 minutos (300s)
$lastCsvSnapshotTime = [DateTime]::MinValue
$requestTimeoutMs = 8000
$azureFeedUrl = "https://azurestatuscdn.azureedge.net/en-us/status/feed/"

if (-not (Test-Path $configFile)) {
    Write-Host "[ERROR] Configuration file '$configFile' not found." -ForegroundColor Red
    exit 1
}

# Inicializar archivo de log de caídas si no existe
if (-not (Test-Path $logFile)) {
    $initLogHeader = "# ==============================================================================`r`n# DAVITA IT - NOC INCIDENT & OUTAGE AUDIT LOG`r`n# ==============================================================================`r`n"
    Set-Content -Path $logFile -Value $initLogHeader -Encoding UTF8
}

# Tablas de memoria
$stats = @{}
$history = @{}
$lastFailed = @{}
$outageStartTime = @{}
$historyLength = 10

# 3. RECUPERAR HISTORIAL PREVIO DESDE CSV (Persistencia entre reinicios)
if (Test-Path $csvDbFile) {
    try {
        $importedData = Import-Csv -Path $csvDbFile
        $grouped = $importedData | Group-Object Url
        foreach ($grp in $grouped) {
            $latestRow = $grp.Group[-1]
            $u = $grp.Name
            $stats[$u] = @{
                Success = [int]$latestRow.Success
                Failure = [int]$latestRow.Failure
            }
        }
    } catch {}
}

function Get-PaloAltoCloudHealth {
    try {
        $paloUrl = "https://status.paloaltonetworks.com/api/v2/summary.json"
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
        $json = $wc.DownloadString($paloUrl)
        $wc.Dispose()
        $data = $json | ConvertFrom-Json

        # Buscar componentes relacionados a Prisma Access, SASE o GlobalProtect
        $saseComponents = $data.components | Where-Object { $_.name -match "Prisma Access|GlobalProtect|SASE|Cloud" }
        $impacted = $saseComponents | Where-Object { $_.status -ne "operational" }

        if ($impacted.Count -gt 0) {
            $firstName = $impacted[0].name
            $firstStatus = $impacted[0].status
            return [PSCustomObject]@{ Status = "[ SASE / PRISMA: ALERT - $firstName ($firstStatus) ]"; Color = "Red" }
        } elseif ($data.status.indicator -ne "none") {
            return [PSCustomObject]@{ Status = "[ SASE / PRISMA: DEGRADED - $($data.status.description) ]"; Color = "Yellow" }
        } else {
            return [PSCustomObject]@{ Status = "[ SASE / PRISMA: OPERATIONAL ]"; Color = "Green" }
        }
    } catch {
        return [PSCustomObject]@{ Status = "[ SASE / PRISMA: Status Unavailable ]"; Color = "DarkGray" }
    }
}

function Get-AzureCloudHealth {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
        $xmlContent = $wc.DownloadString($azureFeedUrl)
        [xml]$xml = $xmlContent
        $wc.Dispose()

        $items = $xml.rss.channel.item
        $rawTitle = ""

        if ($null -ne $items) {
            $firstItem = if ($items -is [array]) { $items[0] } else { $items }
            if ($firstItem) {
                if ($firstItem.title -is [string]) {
                    $rawTitle = $firstItem.title.Trim()
                } elseif ($firstItem.title.InnerText) {
                    $rawTitle = $firstItem.title.InnerText.Trim()
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($rawTitle) -and $rawTitle -notmatch "Normal|Resolved|Mitigated") {
            if ($rawTitle.Length -gt 50) { $rawTitle = $rawTitle.Substring(0, 47) + "..." }
            return [PSCustomObject]@{ Status = "[ AZURE CLOUD: ALERT - $rawTitle ]"; Color = "Red" }
        } else {
            return [PSCustomObject]@{ Status = "[ AZURE CLOUD: OPERATIONAL ]"; Color = "Green" }
        }
    } catch {
        return [PSCustomObject]@{ Status = "[ AZURE CLOUD: Status Unavailable ]"; Color = "DarkGray" }
    }
}

function Test-PortalHealth {
    param (
        [string]$Name,
        [string]$Url
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $statusCode = ""
    $statusText = ""
    $color = "Gray"
    $isSuccess = $false
    $historyCode = "R"

    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = "GET"
        $req.Timeout = $requestTimeoutMs
        $req.ReadWriteTimeout = $requestTimeoutMs
        $req.ServicePoint.Expect100Continue = $false
        $req.Expect = $null
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        $req.AllowAutoRedirect = $false

        $response = [System.Net.HttpWebResponse]$req.GetResponse()
        $stopwatch.Stop()
        $latency = $stopwatch.ElapsedMilliseconds
        $statusCode = [int]$response.StatusCode
        $response.Close()

        if ($latency -gt 3500) {
            # Respuesta lenta / degradación
            $statusText = "DEGRADED"
            $color = "Yellow"
            $historyCode = "Y"
            $isSuccess = $true
        } elseif ($statusCode -eq 200) {
            # Aplicación entregando contenido directamente
            $statusText = "ONLINE"
            $color = "Green"
            $historyCode = "G"
            $isSuccess = $true
        } elseif ($statusCode -in 301, 302, 307, 308) {
            # Redirección esperada a Login / SSO
            $statusText = "AUTH/SSO"
            $color = "Cyan"
            $historyCode = "G"
            $isSuccess = $true
        } elseif ($statusCode -ge 500) {
            # Error de servidor
            $statusText = "SRV ERROR"
            $color = "Red"
            $historyCode = "R"
            $isSuccess = $false
        } else {
            $statusText = "HTTP $statusCode"
            $color = "Yellow"
            $historyCode = "Y"
            $isSuccess = $true
        }
    }
    catch [System.Net.WebException] {
        $stopwatch.Stop()
        $latency = $stopwatch.ElapsedMilliseconds

        if ($_.Exception.Response) {
            $webResp = [System.Net.HttpWebResponse]$_.Exception.Response
            $statusCode = [int]$webResp.StatusCode
            $webResp.Close()

            if ($statusCode -in 401, 403) {
                # Requiere autenticación corporativa
                $statusText = "AUTH REQ"
                $color = "Cyan"
                $isSuccess = $true
                $historyCode = "G"
            } elseif ($statusCode -ge 500) {
                # Error de backend / servidor
                $statusText = "SRV ERROR"
                $color = "Red"
                $isSuccess = $false
                $historyCode = "R"
            } else {
                $statusText = "HTTP $statusCode"
                $color = "Red"
                $isSuccess = $false
                $historyCode = "R"
            }
        } else {
            $exMsg = $_.Exception.Message
            if ($_.Exception.InnerException) { $exMsg += " " + $_.Exception.InnerException.Message }

            if ($exMsg -match "NameResolutionFailure|remote name could not be resolved|nombre remoto no se pudo resolver|No such host") {
                $statusCode = "DNS FAIL"; $statusText = "NO DNS/VPN"
            } elseif ($exMsg -match "Timeout|timed out|se agotó el tiempo") {
                $statusCode = "TIMEOUT"; $statusText = "TIMEOUT"
            } elseif ($exMsg -match "TrustFailure|SecureChannel|SSL|TLS|certificate") {
                $statusCode = "SSL FAIL"; $statusText = "SSL ERROR"
            } elseif ($exMsg -match "ConnectFailure|refused|rechazada") {
                $statusCode = "REFUSED"; $statusText = "REFUSED"
            } else {
                $statusCode = "NET FAIL"; $statusText = "UNREACHABLE"
            }
            $color = "Red"
            $historyCode = "R"
            $isSuccess = $false
        }
    }
    catch {
        $stopwatch.Stop()
        $latency = 0
        $statusCode = "ERROR"; $statusText = "CRASH"; $color = "Red"; $historyCode = "R"; $isSuccess = $false
    }

    return [PSCustomObject]@{
        Name        = $Name
        Url         = $Url
        Status      = $statusText
        Code        = $statusCode
        LatencyMs   = $latency
        LatencyStr  = "$($latency) ms"
        Color       = $color
        IsSuccess   = $isSuccess
        HistoryCode = $historyCode
    }
}


[Console]::CursorVisible = $false
$divider = "=" * 128
$subDivider = "-" * 128

function Show-PaloAltoDetails {
    Clear-Host
    $w = "=" * 128
    $sub = "-" * 128
    Write-Host $w -ForegroundColor Cyan
    Write-Host "                                    PALO ALTO NETWORKS / SASE - DETAILED CLOUD STATUS                                    " -ForegroundColor Cyan
    Write-Host $w -ForegroundColor Cyan

    try {
        Write-Host " Querying live Palo Alto Networks Status API..." -ForegroundColor Gray
        $paloSummaryUrl = "https://status.paloaltonetworks.com/api/v2/summary.json"
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
        $json = $wc.DownloadString($paloSummaryUrl)
        $wc.Dispose()
        $data = $json | ConvertFrom-Json

        Clear-Host
        Write-Host $w -ForegroundColor Cyan
        Write-Host "                                    PALO ALTO NETWORKS / SASE - DETAILED CLOUD STATUS                                    " -ForegroundColor Cyan
        Write-Host $w -ForegroundColor Cyan
        Write-Host " Overall Status : " -NoNewline -ForegroundColor Gray
        $statusColor = if ($data.status.indicator -eq "none") { "Green" } elseif ($data.status.indicator -in "minor", "degraded") { "Yellow" } else { "Red" }
        Write-Host $data.status.description -ForegroundColor $statusColor
        Write-Host " Last Updated   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Source: status.paloaltonetworks.com" -ForegroundColor Gray
        Write-Host ""

        # 1. Incidentes no resueltos
        $activeIncidents = $data.incidents | Where-Object { [string]::IsNullOrWhiteSpace($_.resolved_at) -and $_.status -ne "resolved" }
        Write-Host " ACTIVE INCIDENTS:" -ForegroundColor White
        Write-Host $sub -ForegroundColor DarkGray
        if ($activeIncidents.Count -gt 0) {
            foreach ($inc in $activeIncidents) {
                Write-Host " [!] INCIDENT : $($inc.name)" -ForegroundColor Yellow
                Write-Host "     Status   : $($inc.status.ToUpper())" -ForegroundColor Cyan
                Write-Host "     Impact   : $($inc.impact)" -ForegroundColor Gray
                if ($inc.incident_updates -and $inc.incident_updates.Count -gt 0) {
                    $latestBody = $inc.incident_updates[0].body -replace '<[^>]+>', ' ' -replace '&nbsp;', ' '
                    if ($latestBody.Length -gt 250) { $latestBody = $latestBody.Substring(0, 247) + "..." }
                    Write-Host "     Latest   : $latestBody" -ForegroundColor Gray
                }
                Write-Host ""
            }
        } else {
            Write-Host " [OK] No active unresolved incidents reported by Palo Alto Networks." -ForegroundColor Green
            Write-Host ""
        }

        # 2. Desglose de Componentes Principales SASE
        Write-Host " COMPONENT BREAKDOWN:" -ForegroundColor White
        Write-Host $sub -ForegroundColor DarkGray

        $keyComponents = $data.components | Where-Object { 
            $_.name -match "Prisma|GlobalProtect|Strata|SASE|Cloud Identity|Logging|Browser|SDWAN" 
        }

        # Primero los degradados o con problemas
        $degradedList = $keyComponents | Where-Object { $_.status -ne "operational" }
        foreach ($c in $degradedList) {
            Write-Host (" [!] {0,-40} Status: {1}" -f $c.name, $c.status) -ForegroundColor Yellow
        }

        # Luego los operativos
        $operationalList = $keyComponents | Where-Object { $_.status -eq "operational" }
        foreach ($c in $operationalList) {
            Write-Host (" [OK] {0,-39} Status: operational" -f $c.name) -ForegroundColor Green
        }

    } catch {
        Write-Host " [ERROR] Could not fetch detailed status from Palo Alto Networks: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host $w -ForegroundColor Cyan
    Write-Host " Press any key to return to Main Monitor..." -ForegroundColor Cyan
    [Console]::ReadKey($true) | Out-Null
}

try {
    while ($true) {
        $lines = Get-Content $configFile | Where-Object { $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") }
        $azureHealth = Get-AzureCloudHealth
        $paloHealth  = Get-PaloAltoCloudHealth

        Clear-Host

        # Estado de snapshot en DB
        $dbStatusText = if ($lastCsvSnapshotTime -ne [DateTime]::MinValue) {
            "Last snapshot: $($lastCsvSnapshotTime.ToString('HH:mm:ss')) (history.csv)"
        } else {
            "First snapshot pending (at 5 min mark)"
        }

        Write-Host $divider -ForegroundColor Cyan
        Write-Host "                                      PREVENTIVE PORTAL MONITOR - DAVITA IT                                      " -ForegroundColor Cyan
        Write-Host $divider -ForegroundColor Cyan
        Write-Host " Last Check        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Interval: $intervalSeconds sec" -ForegroundColor Gray
        Write-Host " MS Infrastructure : " -NoNewline -ForegroundColor Gray
        Write-Host $azureHealth.Status -ForegroundColor $azureHealth.Color
        Write-Host " Palo Alto / SASE  : " -NoNewline -ForegroundColor Gray
        Write-Host $paloHealth.Status -ForegroundColor $paloHealth.Color
        Write-Host " Portales          : " -NoNewline -ForegroundColor Gray
        Write-Host "[*] DaVita (Naranja)   " -ForegroundColor DarkYellow -NoNewline
        Write-Host "[*] TCS Soporte (Cyan)" -ForegroundColor Cyan
        Write-Host " Telemetry DB      : " -NoNewline -ForegroundColor Gray
        Write-Host $dbStatusText -ForegroundColor DarkCyan
        Write-Host " KeepAlive         : " -NoNewline -ForegroundColor Gray
        if ($keepAliveActive) {
            Write-Host "[ ACTIVE: Anti-Sleep ON ]" -ForegroundColor Green
        } else {
            Write-Host "[ INACTIVE ]" -ForegroundColor DarkGray
        }
        Write-Host " Hotkeys           : [1] Interval  [2] Edit List  [3] Scan Now  [4] Outages Log  [5] CSV DB  [6] SASE Details" -ForegroundColor DarkCyan
        Write-Host $subDivider -ForegroundColor DarkGray

        Write-Host ("{0,-14} {1,-22} {2,-8} {3,-10} {4,-13} {5,-12} {6,-10} {7}" -f "STATUS", "PORTAL", "CODE", "LATENCY", "TIMELINE(10)", "VERIF(OK|NO)", "UPTIME %", "URL") -ForegroundColor White
        Write-Host $subDivider -ForegroundColor DarkGray

        $currentScanResults = @()

        foreach ($line in $lines) {
            $parts = $line -split ","
            if ($parts.Count -ge 2) {
                $name = $parts[0].Trim()
                $url = $parts[1].Trim()

                $isSupport = $false
                if ($parts.Count -ge 3 -and $parts[2].Trim().ToUpper() -eq "S") {
                    $isSupport = $true
                }

                $portalNameColor = if ($isSupport) { "Cyan" } else { "DarkYellow" }
                $categoryName = if ($isSupport) { "TCS Support" } else { "DaVita Core" }

                # Asegurar inicialización independiente de cada estructura
                if (-not $stats.ContainsKey($url)) {
                    $stats[$url] = @{ Success = 0; Failure = 0 }
                }
                if (-not $history.ContainsKey($url)) {
                    $history[$url] = New-Object System.Collections.Generic.List[string]
                }
                if (-not $lastFailed.ContainsKey($url)) {
                    $lastFailed[$url] = $false
                }
                if (-not $outageStartTime.ContainsKey($url)) {
                    $outageStartTime[$url] = $null
                }


                $res = Test-PortalHealth -Name $name -Url $url

                # Contadores
                if ($res.IsSuccess) { $stats[$url].Success++ } else { $stats[$url].Failure++ }

                # Timeline
                $history[$url].Add($res.HistoryCode)
                if ($history[$url].Count -gt $historyLength) {
                    $history[$url].RemoveAt(0)
                }

                # Registro de Outages en archivo outages.log
                if (-not $res.IsSuccess) {
                    if (-not $lastFailed[$url]) {
                        $outageStartTime[$url] = Get-Date
                        $logEntry = "[{0}] [OUTAGE DETECTED] Portal: {1,-22} | Status: {2,-12} | Code: {3,-8} | URL: {4}" -f `
                            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $name, $res.Status, $res.Code, $url
                        Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
                    }
                    $lastFailed[$url] = $true
                } else {
                    if ($lastFailed[$url]) {
                        $durationStr = "N/A"
                        if ($outageStartTime[$url]) {
                            $elapsed = (Get-Date) - $outageStartTime[$url]
                            $durationStr = "{0:00}m {1:00}s" -f [int]$elapsed.TotalMinutes, ($elapsed.Seconds % 60)
                        }
                        $logEntry = "[{0}] [RESOLVED]        Portal: {1,-22} | Status: ONLINE       | Downtime: {2,-8} | Latency: {3} | URL: {4}" -f `
                            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $name, $durationStr, $res.LatencyStr, $url
                        Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
                        $outageStartTime[$url] = $null
                    }
                    $lastFailed[$url] = $false
                }

                # Cálculo de Uptime %
                $totalChecks = $stats[$url].Success + $stats[$url].Failure
                $uptimePct = if ($totalChecks -gt 0) { ($stats[$url].Success / $totalChecks) * 100 } else { 100.0 }
                $uptimeColor = if ($uptimePct -ge 99.0) { "Green" } elseif ($uptimePct -ge 95.0) { "Yellow" } else { "Red" }

                # Guardar objeto en memoria para exportar a CSV cada 5 minutos
                $currentScanResults += [PSCustomObject]@{
                    Timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    Portal      = $name
                    Category    = $categoryName
                    Status      = $res.Status
                    Code        = $res.Code
                    LatencyMs   = $res.LatencyMs
                    Success     = $stats[$url].Success
                    Failure     = $stats[$url].Failure
                    UptimePct   = ("{0:N1}" -f $uptimePct)
                    Url         = $url
                }

                # 1. Status Badge (14)
                $badge = "[ {0} ]" -f $res.Status
                Write-Host ("{0,-14}" -f $badge) -ForegroundColor $res.Color -NoNewline

                # 2. Portal Name (22)
                $displayName = if ($res.Name.Length -gt 21) { $res.Name.Substring(0, 19) + ".." } else { $res.Name }
                Write-Host ("{0,-22}" -f $displayName) -ForegroundColor $portalNameColor -NoNewline

                # 3. Code (8)
                Write-Host ("{0,-8}" -f $res.Code) -ForegroundColor Gray -NoNewline

                # 4. Latency (10)
                Write-Host ("{0,-10}" -f $res.LatencyStr) -ForegroundColor Gray -NoNewline

                # 5. Timeline Sparkline (13)
                $padCount = $historyLength - $history[$url].Count
                for ($p = 0; $p -lt $padCount; $p++) {
                    Write-Host "-" -ForegroundColor DarkGray -NoNewline
                }
                foreach ($h in $history[$url]) {
                    switch ($h) {
                        "G" { Write-Host "O" -ForegroundColor Green -NoNewline }
                        "Y" { Write-Host "O" -ForegroundColor Yellow -NoNewline }
                        "R" { Write-Host "X" -ForegroundColor Red -NoNewline }
                    }
                }
                Write-Host "   " -NoNewline

                # 6. Verification (12)
                Write-Host ("{0,3} " -f $stats[$url].Success) -ForegroundColor Green -NoNewline
                Write-Host "| " -ForegroundColor DarkGray -NoNewline
                Write-Host ("{0,-3}   " -f $stats[$url].Failure) -ForegroundColor Red -NoNewline

                # 7. Uptime SLA Percentage (10)
                Write-Host ("{0,6:N1}%   " -f $uptimePct) -ForegroundColor $uptimeColor -NoNewline

                # 8. URL (Visualmente recortada a 34 caracteres)
                $maxUrlLength = 34
                $displayUrl = if ($res.Url.Length -gt $maxUrlLength) {
                    $res.Url.Substring(0, $maxUrlLength - 3) + "..."
                } else {
                    $res.Url
                }
                Write-Host $displayUrl -ForegroundColor DarkGray
            }
        }

        Write-Host $subDivider -ForegroundColor DarkGray

        # --- 4. EXPORTAR SNAPSHOT A CSV CADA 5 MINUTOS ---
        $now = Get-Date
        if ($lastCsvSnapshotTime -eq [DateTime]::MinValue -or ($now - $lastCsvSnapshotTime).TotalSeconds -ge $csvSnapshotIntervalSec) {
            try {
                if (-not (Test-Path $csvDbFile)) {
                    $currentScanResults | Export-Csv -Path $csvDbFile -NoTypeInformation -Encoding UTF8
                } else {
                    $currentScanResults | Export-Csv -Path $csvDbFile -NoTypeInformation -Encoding UTF8 -Append
                }
                $lastCsvSnapshotTime = $now
            } catch {}
        }

        Write-Host ""

        # Bucle de cuenta regresiva
        $triggerNextScan = $false
        for ($s = $intervalSeconds; $s -gt 0; $s--) {
            $mins = [math]::Floor($s / 60)
            $secs = $s % 60
            $timeString = "{0:00}m {1:00}s" -f [int]$mins, [int]$secs

            if ($keepAliveEngine -eq "F15" -and ($s % 60 -eq 0) -and $null -ne $wscriptShell) {
                try { $wscriptShell.SendKeys("{F15}") } catch {}
            }

            Write-Host ("`r [>>] Next scan in: $timeString | [1] Interval | [2] Edit | [3] Scan | [4] Outages | [5] CSV | [6] SASE Details   ") -NoNewline -ForegroundColor Cyan

            for ($k = 0; $k -lt 10; $k++) {
                if ([Console]::KeyAvailable) {
                    $keyPressed = [Console]::ReadKey($true)

                    if ($keyPressed.KeyChar -eq '1') {
                        [Console]::CursorVisible = $true
                        Write-Host "`n"
                        $newVal = Read-Host " Enter new scan interval in seconds (current: $intervalSeconds)"
                        if ($newVal -match '^\d+$' -and [int]$newVal -ge 5) {
                            $intervalSeconds = [int]$newVal
                            Write-Host " [OK] Interval updated to $intervalSeconds seconds. Scanning now..." -ForegroundColor Green
                        } else {
                            Write-Host " [!] Invalid input. Keeping $intervalSeconds seconds." -ForegroundColor Yellow
                        }
                        Start-Sleep -Seconds 1
                        [Console]::CursorVisible = $false
                        $triggerNextScan = $true
                        break
                    }
                    elseif ($keyPressed.KeyChar -eq '2') {
                        Write-Host "`n [OK] Opening '$configFile' in Notepad... Save, close, and press [3] to reload." -ForegroundColor Yellow
                        Start-Process notepad.exe -ArgumentList "`"$configFile`""
                        Start-Sleep -Seconds 1
                    }
                    elseif ($keyPressed.KeyChar -eq '3') {
                        Write-Host "`n [OK] Forcing immediate scan and reloading '$configFile'..." -ForegroundColor Green
                        Start-Sleep -Milliseconds 400
                        $triggerNextScan = $true
                        break
                    }
                    elseif ($keyPressed.KeyChar -eq '4') {
                        Write-Host "`n [OK] Opening '$logFile' in Notepad..." -ForegroundColor Yellow
                        Start-Process notepad.exe -ArgumentList "`"$logFile`""
                        Start-Sleep -Seconds 1
                    }
                    elseif ($keyPressed.KeyChar -eq '5') {
                        Write-Host "`n [OK] Opening '$csvDbFile' in default viewer/Excel..." -ForegroundColor Yellow
                        Start-Process notepad.exe -ArgumentList "`"$csvDbFile`""
                        Start-Sleep -Seconds 1
                    }
                    elseif ($keyPressed.KeyChar -eq '6') {
                        Show-PaloAltoDetails
                        $triggerNextScan = $true
                        break
                    }

                }
                Start-Sleep -Milliseconds 100
            }

            if ($triggerNextScan) { break }
        }
    }
}
finally {
    if ($keepAliveActive -and $keepAliveEngine -eq "API") {
        try { [void][Win32.Kernel32]::SetThreadExecutionState(0x80000000) } catch {}
    }
    if ($null -ne $wscriptShell) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wscriptShell) | Out-Null } catch {}
    }
    [Console]::CursorVisible = $true
    Write-Host "`n`nMonitor stopped. Power management restored." -ForegroundColor Yellow
}
