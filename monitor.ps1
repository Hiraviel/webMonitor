<#
================================================================================
 PREVENTIVE PORTAL MONITOR - IT & SUPPORT (v4.5 Modular NOC Edition)
 - Root Orchestrator: Cadence management, scan dispatch, and hotkeys
 - Layer 1 Circuit Breaker: Probe Egress verification (Loopback + Anycast DNS)
 - Layer 2 Circuit Breaker: Fleet Blast Radius Consensus (Local Route/VPN drop)
================================================================================
#>

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
[Console]::CursorVisible = $false

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$srcDir    = Join-Path $scriptDir "src"

if (-not (Test-Path $srcDir)) {
    Write-Host "[ERROR] Modular directory '$srcDir' not found." -ForegroundColor Red
    exit 1
}

# Carga de modulos via Dot-Sourcing
. (Join-Path $srcDir "KeepAlive.ps1")
. (Join-Path $srcDir "Network.ps1")
. (Join-Path $srcDir "Telemetry.ps1")
. (Join-Path $srcDir "Views.ps1")

$configFile = Join-Path $scriptDir "portales.txt"
$logFile    = Join-Path $scriptDir "outages.log"
$csvDbFile  = Join-Path $scriptDir "history.csv"

$intervalSeconds   = 120
$portalTimeoutMs   = 3500
$cloudApiTimeoutMs = 3500
$lastScanDurationMs = 0
$lastScanDurationSec = 0

if (-not (Test-Path $configFile)) {
    Write-Host "[ERROR] Configuration file '$configFile' not found." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $logFile)) {
    $initLogHeader = "# ==============================================================================`r`n# IT SERVICES - NOC INCIDENT & OUTAGE AUDIT LOG`r`n# ==============================================================================`r`n"
    Set-Content -Path $logFile -Value $initLogHeader -Encoding UTF8
}

Initialize-KeepAlive
Initialize-Telemetry -csvDbFile $csvDbFile

# Purgar residuos iniciales de compilacion C# del proceso antes de arrancar la UI
if ($global:NativeEngineAvailable) {
    try { [FleetProbe.NativeScanner]::TrimWorkingSet() } catch {}
}

Clear-Host
try {
    [Console]::CursorVisible = $false
    if ([Console]::BufferWidth -lt 128) { [Console]::BufferWidth = 128 }
    if ([Console]::WindowWidth -lt 128) { [Console]::WindowWidth = 128 }
} catch {}

$scanCycleCount = 0
try {
    while ($true) {
        $cycleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $lines = Get-Content $configFile | Where-Object { $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") }

        # CAPA 1: Probe Egress Check
        $probeHealth = Test-ProbeEgressHealth
        $azureHealth = Get-AzureCloudHealth -timeoutMs $cloudApiTimeoutMs
        $paloHealth  = Get-PaloAltoCloudHealth  -timeoutMs $cloudApiTimeoutMs
        $fleetKpis   = Get-FleetKpis

        # Renderizado de Encabezado Principal
        Render-MainHeader -intervalSeconds $intervalSeconds `
                          -scanDurationMs $lastScanDurationMs `
                          -azureHealth $azureHealth `
                          -paloHealth $paloHealth `
                          -fleetKpis $fleetKpis `
                          -probeHealth $probeHealth

        if (-not $probeHealth.IsHealthy) {
            # CIRCUIT BREAKER CAPA 1: Maquina sin salida
            Write-Host ""
            Write-Host " [!] PROBE OFFLINE: Local network link unreachable. Scan suspended to protect SLA & Incident metrics." -ForegroundColor Yellow
            Write-Host " [!] Monitored targets will not be penalized. Retrying link in next cycle..." -ForegroundColor DarkGray
            Write-Host $global:subDivider -ForegroundColor DarkGray

            $cycleStopwatch.Stop()
            $lastScanDurationMs = [int]$cycleStopwatch.ElapsedMilliseconds
            $lastScanDurationSec = [int][Math]::Ceiling($cycleStopwatch.Elapsed.TotalSeconds)

            # BLINDAJE DE MEMORIA RAM: Desfragmentacion de Heap y Purga de WorkingSet
            $scanCycleCount++
            if ($scanCycleCount % 10 -eq 0) {
                if ($global:NativeEngineAvailable) {
                    try { [FleetProbe.NativeScanner]::TrimWorkingSet() } catch {}
                } else {
                    [System.GC]::Collect()
                    [System.GC]::WaitForPendingFinalizers()
                    [System.GC]::Collect()
                }
            }
            $remainingWaitSec = [Math]::Min(20, $intervalSeconds)
        }
        else {
            # PASO 1: Parsear portales de inventario (C# FastConfigParser 0.05ms)
            $scanItems = @()
            if ($global:NativeEngineAvailable) {
                try {
                    $fastPortals = [FleetProbe.FastConfigParser]::ParseConfigFile($configFile)
                    foreach ($fp in $fastPortals) {
                        $global:portalCategory[$fp.Url] = @{
                            Name       = $fp.Name
                            IsSupport  = $fp.IsSupport
                            IsIntranet = $fp.IsIntranet
                        }
                        $scanItems += [PSCustomObject]@{
                            Name          = $fp.Name
                            Url           = $fp.Url
                            IsSupport     = $fp.IsSupport
                            IsIntranet    = $fp.IsIntranet
                            CategoryName  = $fp.CategoryName
                            CategoryColor = $fp.CategoryColor
                            Health        = $null
                        }
                    }
                } catch {}
            }

            if ($scanItems.Count -eq 0) {
                foreach ($line in $lines) {
                    $parts = $line -split ","
                    if ($parts.Count -ge 2) {
                        $name = $parts[0].Trim()
                        $url  = $parts[1].Trim()
                        $tags = if ($parts.Count -ge 3) {
                            ($parts[2..($parts.Count - 1)] | ForEach-Object { $_.Trim().ToUpper() })
                        } else { @() }

                        $isSupport  = ("S" -in $tags)
                        $isIntranet = ("INT" -in $tags -or $url -match "\.corp" -or $url -match "\.gcp\." -or $url -match "citrixstore" -or $url -match "paweb")
                        $categoryName  = if ($isSupport) { "Support" } else { "IT Core" }
                        $categoryColor = if ($isSupport) { "Cyan" } else { "DarkYellow" }

                        $global:portalCategory[$url] = @{
                            Name       = $name
                            IsSupport  = $isSupport
                            IsIntranet = $isIntranet
                        }

                        $scanItems += [PSCustomObject]@{
                            Name          = $name
                            Url           = $url
                            IsSupport     = $isSupport
                            IsIntranet    = $isIntranet
                            CategoryName  = $categoryName
                            CategoryColor = $categoryColor
                            Health        = $null
                        }
                    }
                }
            }

            # PASO 2: Dibujar Encabezado de Tabla y Registrar Coordenada Base
            $headerRow = try { [Console]::CursorTop } catch { 10 }
            Render-TableHeader -rowIndex $headerRow
            $portalBaseRow = $headerRow + 2

            # Callback Reactivo: cada portal pinta su fila via Win32 Double-Buffer en <0.01ms
            $onPortalComplete = {
                param($idx, $healthRes)
                $portalItem = $scanItems[$idx]
                $portalItem.Health = $healthRes

                $sCount = if ($global:stats.ContainsKey($portalItem.Url)) { $global:stats[$portalItem.Url].Success } else { 0 }
                $fCount = if ($global:stats.ContainsKey($portalItem.Url)) { $global:stats[$portalItem.Url].Failure } else { 0 }
                $tot = $sCount + $fCount
                $upPct = if ($tot -gt 0) { ($sCount / $tot) * 100 } else { 100.0 }

                $rowY = $portalBaseRow + $idx
                try { [Console]::SetCursorPosition(0, $rowY) } catch {}
                Render-PortalRow -res $healthRes `
                                 -categoryColor $portalItem.CategoryColor `
                                 -successCount $sCount `
                                 -failureCount $fCount `
                                 -uptimePct $upPct `
                                 -historyList $global:history[$portalItem.Url] `
                                 -rowIndex $rowY
            }

            # Ejecutar sondeo paralelo en streaming reactivo con 10 workers
            $rawResults = Invoke-FleetHealthScanStreaming -portals $scanItems `
                                                         -timeoutMs $portalTimeoutMs `
                                                         -maxThreads 10 `
                                                         -OnPortalComplete $onPortalComplete

            # Ubicar cursor tras la tabla
            try { [Console]::SetCursorPosition(0, $portalBaseRow + $scanItems.Count) } catch {}

            # CAPA 2: EVALUACION SEGMENTADA DE CONSENSO (PUBLIC SAAS VS INTRANET VPN)
            $segmentedCircuit = Test-SegmentedBlastRadius -scanItems $scanItems
            $blastRadius = Test-FleetBlastRadius -scanResults $rawResults -threshold 0.50

            # PASO 3: Actualizar telemetria de incidencias y congelamientos
            $currentScanResults = @()
            for ($i = 0; $i -lt $scanItems.Count; $i++) {
                $item = $scanItems[$i]
                $itemSuppressed = if ($item.IsIntranet) {
                    $segmentedCircuit.IntranetDisrupted -or $segmentedCircuit.GlobalDisrupted
                } else {
                    $segmentedCircuit.GlobalDisrupted
                }

                Update-IncidentState -name $item.Name `
                                     -url $item.Url `
                                     -healthResult $item.Health `
                                     -logFile $logFile `
                                     -SuppressFailure:$itemSuppressed

                # Si el portal fue congelado por Circuit Breaker, refrescar esa fila en pantalla
                if ($itemSuppressed -and $item.Health.IsSuccess -eq $false) {
                    $rowY = $portalBaseRow + $i
                    try { [Console]::SetCursorPosition(0, $rowY) } catch {}
                    $sCount = $global:stats[$item.Url].Success
                    $fCount = $global:stats[$item.Url].Failure
                    $tot = $sCount + $fCount
                    $upPct = if ($tot -gt 0) { ($sCount / $tot) * 100 } else { 100.0 }
                    Render-PortalRow -res $item.Health `
                                     -categoryColor $item.CategoryColor `
                                     -successCount $sCount `
                                     -failureCount $fCount `
                                     -uptimePct $upPct `
                                     -historyList $global:history[$item.Url] `
                                     -IsBlastRadiusDisrupted:$true `
                                     -rowIndex $rowY
                }

                $totalChecks = $global:stats[$item.Url].Success + $global:stats[$item.Url].Failure
                $uptimePct = if ($totalChecks -gt 0) { ($global:stats[$item.Url].Success / $totalChecks) * 100 } else { 100.0 }

                $currentScanResults += [PSCustomObject]@{
                    Timestamp        = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    Portal           = $item.Name
                    Category         = $item.CategoryName
                    Status           = $item.Health.Status
                    Code             = $item.Health.Code
                    LatencyMs        = $item.Health.LatencyMs
                    Success          = $global:stats[$item.Url].Success
                    Failure          = $global:stats[$item.Url].Failure
                    UptimePct        = ("{0:N1}" -f $uptimePct)
                    Incidents        = $global:stats[$item.Url].Incidents
                    TotalDowntimeSec = $global:stats[$item.Url].TotalDowntimeSec
                    Url              = $item.Url
                }
            }

            try { [Console]::SetCursorPosition(0, $portalBaseRow + $scanItems.Count) } catch {}
            Write-Host $global:subDivider -ForegroundColor DarkGray

            # AVISO EN PANTALLA SI EL CIRCUIT BREAKER DE CAPA 2 SE ACTIVO
            if ($segmentedCircuit.GlobalDisrupted) {
                Write-Host " [!] BLAST RADIUS WARNING: Public Egress/Cloud Transport Disrupted. Fleet SLA FROZEN." -ForegroundColor Yellow
                Write-Host $global:subDivider -ForegroundColor DarkGray
            } elseif ($segmentedCircuit.IntranetDisrupted) {
                Write-Host (" [!] VPN / INTRANET DISRUPTED: {0} of {1} INT portals unreachable. Intranet SLA FROZEN (Public Cloud Monitoring Active)." -f $segmentedCircuit.IntranetFailures, $segmentedCircuit.IntranetTotal) -ForegroundColor DarkYellow
                Write-Host $global:subDivider -ForegroundColor DarkGray
            }

            # Guardar snapshot solo si no hubo disrupcion masiva
            if (-not $blastRadius.IsDisrupted) {
                Save-TelemetrySnapshot -results $currentScanResults -csvDbFile $csvDbFile
            }

            $cycleStopwatch.Stop()
            $lastScanDurationMs = [int]$cycleStopwatch.ElapsedMilliseconds
            $lastScanDurationSec = [int][Math]::Ceiling($cycleStopwatch.Elapsed.TotalSeconds)
            $remainingWaitSec = [Math]::Max(1, $intervalSeconds - $lastScanDurationSec)
        }

        Write-Host ""

        # Manejo de Overrun
        if ($remainingWaitSec -le 0) {
            Write-Host " [!] OVERRUN: Scan took ${lastScanDurationSec}s (exceeded interval ${intervalSeconds}s). Next cycle starting..." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }

        # Cuenta regresiva interactiva con hotkeys [1] a [7]
        $triggerNextScan = $false
        for ($s = $remainingWaitSec; $s -gt 0; $s--) {
            $mins = [math]::Floor($s / 60)
            $secs = $s % 60
            $timeString = "{0:00}m {1:00}s" -f [int]$mins, [int]$secs

            if ($s % 60 -eq 0) { Send-KeepAliveHeartbeat }

            $scanDurDisp = if ($lastScanDurationMs -ge 1000) { "{0:N1}s" -f ($lastScanDurationMs / 1000.0) } else { "${lastScanDurationMs}ms" }
            Write-Host ("`r [>>] Next scan in: $timeString | Scan Duration: $scanDurDisp | [1] Interval | [2] Edit | [3] Scan | [4] Outages | [5] CSV | [6] SASE | [7] NOC Metrics   ") -NoNewline -ForegroundColor Cyan

            for ($k = 0; $k -lt 10; $k++) {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)

                    if ($key.KeyChar -eq '1') {
                        [Console]::CursorVisible = $true
                        Write-Host "`n"
                        $newVal = Read-Host " Enter new scan interval in seconds (current: $intervalSeconds)"
                        if ($newVal -match '^\d+$' -and [int]$newVal -ge 5) {
                            $intervalSeconds = [int]$newVal
                            Write-Host " [OK] Interval updated to $intervalSeconds seconds. Scanning now..." -ForegroundColor Green
                        }
                        Start-Sleep -Seconds 1
                        [Console]::CursorVisible = $false
                        $triggerNextScan = $true
                        break
                    }
                    elseif ($key.KeyChar -eq '2') {
                        Write-Host "`n [OK] Opening '$configFile' in Notepad..." -ForegroundColor Yellow
                        Start-Process notepad.exe -ArgumentList "`"$configFile`""
                        Start-Sleep -Seconds 1
                    }
                    elseif ($key.KeyChar -eq '3') {
                        Write-Host "`n [OK] Forcing immediate scan..." -ForegroundColor Green
                        Start-Sleep -Milliseconds 400
                        $triggerNextScan = $true
                        break
                    }
                    elseif ($key.KeyChar -eq '4') {
                        Write-Host "`n [OK] Opening '$logFile' in Notepad..." -ForegroundColor Yellow
                        Start-Process notepad.exe -ArgumentList "`"$logFile`""
                        Start-Sleep -Seconds 1
                    }
                    elseif ($key.KeyChar -eq '5') {
                        Write-Host "`n [OK] Opening '$csvDbFile' in Excel/Viewer..." -ForegroundColor Yellow
                        Start-Process notepad.exe -ArgumentList "`"$csvDbFile`""
                        Start-Sleep -Seconds 1
                    }
                    elseif ($key.KeyChar -eq '6') {
                        Show-PaloAltoDetails
                        $triggerNextScan = $true
                        break
                    }
                    elseif ($key.KeyChar -eq '7') {
                        Show-NocMetricsDetails
                        $triggerNextScan = $true
                        break
                    }
                }
                Start-Sleep -Milliseconds 100
            }

            if ($triggerNextScan) { break }
        }
        Write-Host ("`r [>>] Scanning fleet in parallel... Please wait...                                                         ") -NoNewline -ForegroundColor Green
    }
}
finally {
    Restore-KeepAlive
    [Console]::CursorVisible = $true
    Write-Host "`n`nMonitor stopped. Power management restored." -ForegroundColor Yellow
}
