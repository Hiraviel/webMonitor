# ==============================================================================
# TELEMETRY MODULE - PERSISTENCE, INCIDENT LIFECYCLE & NOC METRICS (CAPA 2 & 3)
# ==============================================================================

# Inicializacion defensiva de tablas de estado global
if ($null -eq $global:stats)                { $global:stats = @{} }
if ($null -eq $global:sessionStats)         { $global:sessionStats = @{} }
if ($null -eq $global:history)              { $global:history = @{} }
$global:timeline = $global:history
if ($null -eq $global:portalCategory)       { $global:portalCategory = @{} }
if ($null -eq $global:consecutiveFailures)  { $global:consecutiveFailures = @{} }
if ($null -eq $global:isHardOutage)         { $global:isHardOutage = @{} }
if ($null -eq $global:softOutageStartTime)  { $global:softOutageStartTime = @{} }
if ($null -eq $global:outageStartTime)      { $global:outageStartTime = @{} }
if ($null -eq $global:resolvedIncidents)    { $global:resolvedIncidents = 0 }
if ($null -eq $global:totalDowntimeSeconds) { $global:totalDowntimeSeconds = 0 }

function Initialize-Telemetry {
    param(
        [Alias("csvFile", "path", "csv")]
        [string]$csvDbFile
    )

    if ($null -eq $global:stats)          { $global:stats = @{} }
    if ($null -eq $global:sessionStats)   { $global:sessionStats = @{} }
    if ($null -eq $global:history)        { $global:history = @{} }
    $global:timeline = $global:history
    if ($null -eq $global:portalCategory) { $global:portalCategory = @{} }

    if ($global:NativeEngineAvailable -and -not [string]::IsNullOrWhiteSpace($csvDbFile) -and (Test-Path $csvDbFile)) {
        try {
            [FleetProbe.FleetTelemetryEngine]::Instance.InitializeFromCsv($csvDbFile)
            foreach ($kvp in [FleetProbe.FleetTelemetryEngine]::Instance.Portals) {
                $p = $kvp.Value
                $global:stats[$p.Url] = [PSCustomObject]@{ Success = $p.HistSuccess; Failure = $p.HistFailure }
                $global:sessionStats[$p.Url] = [PSCustomObject]@{ Success = $p.SessionSuccess; Failure = $p.SessionFailure }
            }
            return
        } catch {}
    }

    
    if (-not [string]::IsNullOrWhiteSpace($csvDbFile) -and (Test-Path $csvDbFile)) {
        try {
            $rows = Import-Csv -Path $csvDbFile -ErrorAction Stop
            foreach ($row in $rows) {
                if ($row.Url) {
                    $s = 0; $f = 0
                    [int]::TryParse($row.Success, [ref]$s) | Out-Null
                    [int]::TryParse($row.Failure, [ref]$f) | Out-Null
                    $global:stats[$row.Url] = [PSCustomObject]@{ Success = $s; Failure = $f }
                }
            }
        } catch {
            # Si el CSV esta en uso o corrupto, arrancar en limpio
        }
    }
}

function Initialize-TelemetryDatabase { Initialize-Telemetry @args }

function Add-TimelineSample {
    param(
        [string]$url,
        [string]$symbol
    )

    if ($null -eq $global:history) {
        $global:history = @{}
    }
    if (-not $global:history.ContainsKey($url)) {
        $global:history[$url] = New-Object 'System.Collections.Generic.Queue[string]' 15
    }

    $q = $global:history[$url]
    # Si vino de una sesion anterior como array o list, convertir a Queue
    if ($q -isnot [System.Collections.Generic.Queue[string]]) {
        $oldItems = @($q)
        $q = New-Object 'System.Collections.Generic.Queue[string]' 15
        foreach ($it in $oldItems) { $q.Enqueue([string]$it) }
        $global:history[$url] = $q
    }

    while ($q.Count -ge 10) {
        $null = $q.Dequeue()
    }
    $q.Enqueue([string]$symbol)
    $global:timeline = $global:history
}

# ==============================================================================
# CAPA 2: MOTOR DE CONSENSO ESTADISTICO / BLAST RADIUS CIRCUIT BREAKER
# ==============================================================================
function Test-SegmentedBlastRadius {
    param(
        [Alias("items", "results")]
        $scanItems,
        [double]$globalThreshold = 0.50,
        [double]$intranetThreshold = 0.50
    )

    if (-not $scanItems -or $scanItems.Count -eq 0) {
        return [PSCustomObject]@{
            GlobalDisrupted   = $false
            IntranetDisrupted = $false
            IntranetFailures  = 0
            IntranetTotal     = 0
            PublicFailures    = 0
            PublicTotal       = 0
            IsDisrupted       = $false
        }

    # FAST PATH: Evaluacion C# de Circuito de Consenso Segmentado (0.001ms)
    if ($global:NativeEngineAvailable) {
        try {
            $isIntranetArr = New-Object bool[] $scanItems.Count
            $isSuccessArr  = New-Object bool[] $scanItems.Count
            for ($i = 0; $i -lt $scanItems.Count; $i++) {
                $it = $scanItems[$i]
                $isIntranetArr[$i] = [bool]$it.IsIntranet
                $res = if ($it.Health) { $it.Health } else { $it }
                $isFail = ($res.IsSuccess -eq $false -and ($res.Status -in "NO DNS/VPN", "TIMEOUT", "REFUSED", "CONN REFUSED", "NET ERROR", "SSL ERROR", "ERR" -or $res.Code -eq "ERR"))
                $isSuccessArr[$i]  = (-not $isFail)
            }
            $fastBr = [FleetProbe.FleetTelemetryEngine]::EvaluateSegmented($isIntranetArr, $isSuccessArr, $globalThreshold, $intranetThreshold)
            return [PSCustomObject]@{
                GlobalDisrupted   = $fastBr.GlobalDisrupted
                IntranetDisrupted = $fastBr.IntranetDisrupted
                IntranetFailures  = $fastBr.IntranetFailures
                IntranetTotal     = $fastBr.IntranetTotal
                PublicFailures    = $fastBr.PublicFailures
                PublicTotal       = $fastBr.PublicTotal
                IsDisrupted       = $fastBr.IsDisrupted
            }
        } catch {}
    }

    }

    $pubTotal = 0; $pubFail = 0
    $intTotal = 0; $intFail = 0

    foreach ($item in $scanItems) {
        $res = if ($item.Health) { $item.Health } else { $item }
        $isFail = ($res.IsSuccess -eq $false -and ($res.Status -in "NO DNS/VPN", "TIMEOUT", "REFUSED", "CONN REFUSED", "NET ERROR", "SSL ERROR", "ERR" -or $res.Code -eq "ERR"))

        if ($item.IsIntranet) {
            $intTotal++
            if ($isFail) { $intFail++ }
        } else {
            $pubTotal++
            if ($isFail) { $pubFail++ }
        }
    }

    $intDisrupted = ($intTotal -ge 2 -and ($intFail / $intTotal) -ge $intranetThreshold)
    $pubDisrupted = ($pubTotal -ge 3 -and ($pubFail / $pubTotal) -ge $globalThreshold)

    return [PSCustomObject]@{
        GlobalDisrupted   = $pubDisrupted
        IntranetDisrupted = $intDisrupted
        IntranetFailures  = $intFail
        IntranetTotal     = $intTotal
        PublicFailures    = $pubFail
        PublicTotal       = $pubTotal
        IsDisrupted       = ($pubDisrupted -or $intDisrupted)
    }
}

function Test-FleetBlastRadius {
    param(
        [Alias("results", "cycleResults")]
        $scanResults,
        [double]$threshold = 0.60
    )

    if (-not $scanResults -or $scanResults.Count -eq 0) {
        return [PSCustomObject]@{
            IsDisrupted       = $false
            TransportFailures = 0
            TotalPortals      = 0
            FailureRatio      = 0.0
            Message           = "No scan results"
        }
    }

    $totalPortals = $scanResults.Count
    $transportFailures = 0

    foreach ($item in $scanResults) {
        $res = if ($item.Health) { $item.Health } else { $item }
        if ($res.IsSuccess -eq $false) {
            $st = $res.Status
            if ($st -in "NO DNS/VPN", "TIMEOUT", "REFUSED", "CONN REFUSED", "NET ERROR", "SSL ERROR", "ERR") {
                $transportFailures++
            } elseif ($res.Code -eq "ERR") {
                $transportFailures++
            }
        }
    }

    $failureRatio = if ($totalPortals -gt 0) { $transportFailures / $totalPortals } else { 0.0 }
    $isDisrupted = ($failureRatio -ge $threshold)

    return [PSCustomObject]@{
        IsDisrupted       = $isDisrupted
        TransportFailures = $transportFailures
        TotalPortals      = $totalPortals
        FailureRatio      = $failureRatio
        Message           = if ($isDisrupted) {
            "[!] BLAST RADIUS WARNING: $transportFailures of $totalPortals portals failed network transport simultaneously."
        } else {
            "Normal"
        }
    }
}

# ==============================================================================
# CAPA 3: MOTOR DE ESTADO SOFT VS HARD OUTAGE
# ==============================================================================
function Update-IncidentState {
    param(
        [string]$name,
        [string]$url,
        [PSCustomObject]$healthResult,
        [string]$logFile,
        [switch]$SuppressFailure
    )

    if ($null -eq $global:stats)               { $global:stats = @{} }
    if ($null -eq $global:sessionStats)        { $global:sessionStats = @{} }
    if ($null -eq $global:history)             { $global:history = @{} }
    $global:timeline = $global:history
    if ($null -eq $global:portalCategory)      { $global:portalCategory = @{} }
    if ($null -eq $global:consecutiveFailures) { $global:consecutiveFailures = @{} }
    if ($null -eq $global:isHardOutage)        { $global:isHardOutage = @{} }
    if ($null -eq $global:softOutageStartTime) { $global:softOutageStartTime = @{} }
    if ($null -eq $global:outageStartTime)     { $global:outageStartTime = @{} }

    if (-not $global:stats.ContainsKey($url)) {
        $global:stats[$url] = [PSCustomObject]@{ Success = 0; Failure = 0 }
    }
    if (-not $global:sessionStats.ContainsKey($url)) {
        $global:sessionStats[$url] = [PSCustomObject]@{ Success = 0; Failure = 0 }
    }
    if (-not $global:history.ContainsKey($url)) {
        $global:history[$url] = New-Object 'System.Collections.Generic.Queue[string]' 15
    }
    if (-not $global:consecutiveFailures.ContainsKey($url)) {
        $global:consecutiveFailures[$url] = 0
    }
    if (-not $global:isHardOutage.ContainsKey($url)) {
        $global:isHardOutage[$url] = $false
    }

    # ==========================================================================
    # CASO 1: Portal Respondiendo (ONLINE / DEGRADED / AUTH)
    # ==========================================================================
    if ($healthResult.IsSuccess -eq $true) {
        $global:stats[$url].Success++
        $global:sessionStats[$url].Success++

        $symbol = if ($healthResult.Status -eq "DEGRADED") { "D" } else { "O" }
        Add-TimelineSample -url $url -symbol $symbol

        # Viene de un Hard Outage confirmado?
        if ($global:isHardOutage[$url] -eq $true) {
            $endTime = Get-Date
            $startTime = if ($global:outageStartTime.ContainsKey($url)) { $global:outageStartTime[$url] } else { $endTime }
            $duration = $endTime - $startTime
            $durationSec = [math]::Max(1, [math]::Round($duration.TotalSeconds))
            $durationStr = "{0}m {1}s" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds

            # Registrar resolucion en bitacora oficial
            if ($logFile) {
                $logEntry = "[{0}] [RECOVERED] Portal: {1} | URL: {2} | Downtime: {3} ({4}s)" -f `
                    (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $name, $url, $durationStr, $durationSec
                Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
            }

            $global:resolvedIncidents++
            $global:totalDowntimeSeconds += $durationSec
            $global:outageStartTime.Remove($url)
            $global:isHardOutage[$url] = $false
        }

        # Resetear fallas transitorias silenciosamente (Auto-Healed)
        $global:consecutiveFailures[$url] = 0
        if ($global:softOutageStartTime.ContainsKey($url)) {
            $global:softOutageStartTime.Remove($url)
        }
    }
    # ==========================================================================
    # CASO 2: Falla Suprimida por Blast Radius (Capa 2: Caida de VPN / Ruta)
    # ==========================================================================
    elseif ($SuppressFailure) {
        Add-TimelineSample -url $url -symbol "-"
        # Se congelan los contadores para proteger SLA y no generar alertas
    }
    # ==========================================================================
    # CASO 3: Falla Real de Portal (Evaluacion Soft vs Hard - Capa 3)
    # ==========================================================================
    else {
        $global:stats[$url].Failure++
        $global:sessionStats[$url].Failure++
        Add-TimelineSample -url $url -symbol "X"

        $global:consecutiveFailures[$url]++

        # EVALUACION DE UMBRAL (2 ciclos consecutivos = Hard Outage)
        if ($global:consecutiveFailures[$url] -ge 2) {
            if (-not $global:isHardOutage[$url]) {
                # PROMOCION A HARD OUTAGE
                $global:isHardOutage[$url] = $true

                $startTime = if ($global:softOutageStartTime.ContainsKey($url)) {
                    $global:softOutageStartTime[$url]
                } else {
                    Get-Date
                }
                $global:outageStartTime[$url] = $startTime

                if ($logFile) {
                    $logEntry = "[{0}] [OUTAGE DETECTED] Portal: {1} | URL: {2} | Code: {3} | Reason: Confirmed Hard Outage (2 consecutive cycles)" -f `
                        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $name, $url, $healthResult.Code
                    Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
                }
            }
        } else {
            # CICLO 1: SOFT FAIL (Transitorio en observacion)
            if (-not $global:softOutageStartTime.ContainsKey($url)) {
                $global:softOutageStartTime[$url] = Get-Date
            }
        }
    }
}

function Save-Telemetry {
    param(
        [Alias("csvFile", "path")]
        [string]$csvDbFile,
        [Alias("scanResults", "results")]
        $currentScanResults
    )

    if (-not $global:stats -or $global:stats.Count -eq 0) { return }

    try {
        $exportData = foreach ($url in $global:stats.Keys) {
            $name = $url
            if ($currentScanResults) {
                $matched = $currentScanResults | Where-Object { $_.Url -eq $url } | Select-Object -First 1
                if ($matched) { $name = $matched.Name }
            }
            [PSCustomObject]@{
                Name    = $name
                Url     = $url
                Success = $global:stats[$url].Success
                Failure = $global:stats[$url].Failure
            }
        }
        $exportData | Export-Csv -Path $csvDbFile -NoTypeInformation -Encoding UTF8
    } catch {
        # Escritura silenciosa ante concurrencia
    }
}

function Save-TelemetrySnapshot { Save-Telemetry @args }
function Save-TelemetryDb { Save-Telemetry @args }

# ==============================================================================
# SLA, MTTR & KPIS CALCULATION ENGINES
# ==============================================================================

function Get-FleetSlaPercentage {
    if (-not $global:stats -or $global:stats.Count -eq 0) { return 100.0 }
    $totalSucc = 0
    $totalFail = 0
    foreach ($url in $global:stats.Keys) {
        $totalSucc += $global:stats[$url].Success
        $totalFail += $global:stats[$url].Failure
    }
    $total = $totalSucc + $totalFail
    if ($total -eq 0) { return 100.0 }
    return [math]::Round(($totalSucc / $total) * 100, 1)
}

function Get-SessionSlaPercentage {
    if (-not $global:sessionStats -or $global:sessionStats.Count -eq 0) { return 100.0 }
    $totalSucc = 0
    $totalFail = 0
    foreach ($url in $global:sessionStats.Keys) {
        $totalSucc += $global:sessionStats[$url].Success
        $totalFail += $global:sessionStats[$url].Failure
    }
    $total = $totalSucc + $totalFail
    if ($total -eq 0) { return 100.0 }
    return [math]::Round(($totalSucc / $total) * 100, 1)
}

function Get-FleetMttrFormatted {
    $incidents = if ($global:resolvedIncidents) { $global:resolvedIncidents } else { 0 }
    $downtime  = if ($global:totalDowntimeSeconds) { $global:totalDowntimeSeconds } else { 0 }
    if ($incidents -eq 0 -or $downtime -eq 0) { return "0m 00s" }
    $avgSec = [math]::Round($downtime / $incidents)
    $min = [math]::Floor($avgSec / 60)
    $sec = $avgSec % 60
    return "{0}m {1:D2}s" -f $min, $sec
}

function Get-FleetKpis {

    # FAST PATH: Calculo C# de KPIs de Flota (SLA, MTTR, Outages) en 0.001ms
    if ($global:NativeEngineAvailable) {
        try {
            $k = [FleetProbe.FleetTelemetryEngine]::Instance.ComputeKpis()
            return [PSCustomObject]@{
                HistoricalSla      = $k.HistSla
                HistSla            = $k.HistSla
                SessionSla         = $k.SessSla
                SessSla            = $k.SessSla
                ResolvedIncidents  = $k.Incidents
                Incidents          = $k.Incidents
                FleetMttr          = $k.FleetMttr
                FleetMttrFormatted = $k.FleetMttr
                HardOutagesCount   = $k.HardOutagesCount
                SoftFailsCount     = $k.SoftFailsCount
                OutageDisplay      = $k.OutageDisplay
                OutageColor        = $k.OutageColor
            }
        } catch {}
    }

    $histSla = Get-FleetSlaPercentage
    $sessSla = Get-SessionSlaPercentage
    $mttrStr = Get-FleetMttrFormatted
    $incCount = if ($global:resolvedIncidents) { $global:resolvedIncidents } else { 0 }

    # Conteo de Hard Outages vs Soft Fails (Capa 3)
    $hardOutagesCount = 0
    if ($global:isHardOutage) {
        $hardOutagesCount = ($global:isHardOutage.Values | Where-Object { $_ -eq $true }).Count
    }

    $softFailsCount = 0
    if ($global:consecutiveFailures) {
        $softFailsCount = ($global:consecutiveFailures.Values | Where-Object { $_ -eq 1 }).Count
    }

    $outageDisplay = "$hardOutagesCount"
    if ($softFailsCount -gt 0) {
        $outageDisplay += " ($softFailsCount Soft)"
    }
    $outageColor = if ($hardOutagesCount -gt 0) { "Red" } elseif ($softFailsCount -gt 0) { "Yellow" } else { "Green" }

    return [PSCustomObject]@{
        HistoricalSla      = $histSla
        HistSla            = $histSla
        SessionSla         = $sessSla
        SessSla            = $sessSla
        ResolvedIncidents  = $incCount
        Incidents          = $incCount
        FleetMttr          = $mttrStr
        FleetMttrFormatted = $mttrStr
        ActiveOutagesCount = $hardOutagesCount
        ActiveOutages      = $hardOutagesCount
        SoftFailsCount     = $softFailsCount
        OutageDisplay      = $outageDisplay
        OutageColor        = $outageColor
    }
}param(
        [Alias("csvFile", "path", "csv")]
        [string]$csvDbFile
    )

    if ($global:NativeEngineAvailable -and -not [string]::IsNullOrWhiteSpace($csvDbFile)) {
        try {
            [FleetProbe.FleetTelemetryEngine]::Instance.SaveSnapshotCsv($csvDbFile)
            return
        } catch {}
    }# ==============================================================================
# TELEMETRY MODULE - PERSISTENCE, INCIDENT LIFECYCLE & NOC METRICS (CAPA 2 & 3)
# ==============================================================================

# Inicializacion defensiva de tablas de estado global
if ($null -eq $global:stats)                { $global:stats = @{} }
if ($null -eq $global:sessionStats)         { $global:sessionStats = @{} }
if ($null -eq $global:history)              { $global:history = @{} }
$global:timeline = $global:history
if ($null -eq $global:portalCategory)       { $global:portalCategory = @{} }
if ($null -eq $global:consecutiveFailures)  { $global:consecutiveFailures = @{} }
if ($null -eq $global:isHardOutage)         { $global:isHardOutage = @{} }
if ($null -eq $global:softOutageStartTime)  { $global:softOutageStartTime = @{} }
if ($null -eq $global:outageStartTime)      { $global:outageStartTime = @{} }
if ($null -eq $global:resolvedIncidents)    { $global:resolvedIncidents = 0 }
if ($null -eq $global:totalDowntimeSeconds) { $global:totalDowntimeSeconds = 0 }

function Initialize-Telemetry {
    param(
        [Alias("csvFile", "path", "csv")]
        [string]$csvDbFile
    )

    if ($null -eq $global:stats)          { $global:stats = @{} }
    if ($null -eq $global:sessionStats)   { $global:sessionStats = @{} }
    if ($null -eq $global:history)        { $global:history = @{} }
    $global:timeline = $global:history
    if ($null -eq $global:portalCategory) { $global:portalCategory = @{} }

    if ($global:NativeEngineAvailable -and -not [string]::IsNullOrWhiteSpace($csvDbFile) -and (Test-Path $csvDbFile)) {
        try {
            [FleetProbe.FleetTelemetryEngine]::Instance.InitializeFromCsv($csvDbFile)
            foreach ($kvp in [FleetProbe.FleetTelemetryEngine]::Instance.Portals) {
                $p = $kvp.Value
                $global:stats[$p.Url] = [PSCustomObject]@{ Success = $p.HistSuccess; Failure = $p.HistFailure }
                $global:sessionStats[$p.Url] = [PSCustomObject]@{ Success = $p.SessionSuccess; Failure = $p.SessionFailure }
            }
            return
        } catch {}
    }

    
    if (-not [string]::IsNullOrWhiteSpace($csvDbFile) -and (Test-Path $csvDbFile)) {
        try {
            $rows = Import-Csv -Path $csvDbFile -ErrorAction Stop
            foreach ($row in $rows) {
                if ($row.Url) {
                    $s = 0; $f = 0
                    [int]::TryParse($row.Success, [ref]$s) | Out-Null
                    [int]::TryParse($row.Failure, [ref]$f) | Out-Null
                    $global:stats[$row.Url] = [PSCustomObject]@{ Success = $s; Failure = $f }
                }
            }
        } catch {
            # Si el CSV esta en uso o corrupto, arrancar en limpio
        }
    }
}

function Initialize-TelemetryDatabase { Initialize-Telemetry @args }

function Add-TimelineSample {
    param(
        [string]$url,
        [string]$symbol
    )

    if ($null -eq $global:history) {
        $global:history = @{}
    }
    if (-not $global:history.ContainsKey($url)) {
        $global:history[$url] = New-Object 'System.Collections.Generic.Queue[string]' 15
    }

    $q = $global:history[$url]
    # Si vino de una sesion anterior como array o list, convertir a Queue
    if ($q -isnot [System.Collections.Generic.Queue[string]]) {
        $oldItems = @($q)
        $q = New-Object 'System.Collections.Generic.Queue[string]' 15
        foreach ($it in $oldItems) { $q.Enqueue([string]$it) }
        $global:history[$url] = $q
    }

    while ($q.Count -ge 10) {
        $null = $q.Dequeue()
    }
    $q.Enqueue([string]$symbol)
    $global:timeline = $global:history
}

# ==============================================================================
# CAPA 2: MOTOR DE CONSENSO ESTADISTICO / BLAST RADIUS CIRCUIT BREAKER
# ==============================================================================
function Test-SegmentedBlastRadius {
    param(
        [Alias("items", "results")]
        $scanItems,
        [double]$globalThreshold = 0.50,
        [double]$intranetThreshold = 0.50
    )

    if (-not $scanItems -or $scanItems.Count -eq 0) {
        return [PSCustomObject]@{
            GlobalDisrupted   = $false
            IntranetDisrupted = $false
            IntranetFailures  = 0
            IntranetTotal     = 0
            PublicFailures    = 0
            PublicTotal       = 0
            IsDisrupted       = $false
        }

    # FAST PATH: Evaluacion C# de Circuito de Consenso Segmentado (0.001ms)
    if ($global:NativeEngineAvailable) {
        try {
            $isIntranetArr = New-Object bool[] $scanItems.Count
            $isSuccessArr  = New-Object bool[] $scanItems.Count
            for ($i = 0; $i -lt $scanItems.Count; $i++) {
                $it = $scanItems[$i]
                $isIntranetArr[$i] = [bool]$it.IsIntranet
                $res = if ($it.Health) { $it.Health } else { $it }
                $isFail = ($res.IsSuccess -eq $false -and ($res.Status -in "NO DNS/VPN", "TIMEOUT", "REFUSED", "CONN REFUSED", "NET ERROR", "SSL ERROR", "ERR" -or $res.Code -eq "ERR"))
                $isSuccessArr[$i]  = (-not $isFail)
            }
            $fastBr = [FleetProbe.FleetTelemetryEngine]::EvaluateSegmented($isIntranetArr, $isSuccessArr, $globalThreshold, $intranetThreshold)
            return [PSCustomObject]@{
                GlobalDisrupted   = $fastBr.GlobalDisrupted
                IntranetDisrupted = $fastBr.IntranetDisrupted
                IntranetFailures  = $fastBr.IntranetFailures
                IntranetTotal     = $fastBr.IntranetTotal
                PublicFailures    = $fastBr.PublicFailures
                PublicTotal       = $fastBr.PublicTotal
                IsDisrupted       = $fastBr.IsDisrupted
            }
        } catch {}
    }

    }

    $pubTotal = 0; $pubFail = 0
    $intTotal = 0; $intFail = 0

    foreach ($item in $scanItems) {
        $res = if ($item.Health) { $item.Health } else { $item }
        $isFail = ($res.IsSuccess -eq $false -and ($res.Status -in "NO DNS/VPN", "TIMEOUT", "REFUSED", "CONN REFUSED", "NET ERROR", "SSL ERROR", "ERR" -or $res.Code -eq "ERR"))

        if ($item.IsIntranet) {
            $intTotal++
            if ($isFail) { $intFail++ }
        } else {
            $pubTotal++
            if ($isFail) { $pubFail++ }
        }
    }

    $intDisrupted = ($intTotal -ge 2 -and ($intFail / $intTotal) -ge $intranetThreshold)
    $pubDisrupted = ($pubTotal -ge 3 -and ($pubFail / $pubTotal) -ge $globalThreshold)

    return [PSCustomObject]@{
        GlobalDisrupted   = $pubDisrupted
        IntranetDisrupted = $intDisrupted
        IntranetFailures  = $intFail
        IntranetTotal     = $intTotal
        PublicFailures    = $pubFail
        PublicTotal       = $pubTotal
        IsDisrupted       = ($pubDisrupted -or $intDisrupted)
    }
}

function Test-FleetBlastRadius {
    param(
        [Alias("results", "cycleResults")]
        $scanResults,
        [double]$threshold = 0.60
    )

    if (-not $scanResults -or $scanResults.Count -eq 0) {
        return [PSCustomObject]@{
            IsDisrupted       = $false
            TransportFailures = 0
            TotalPortals      = 0
            FailureRatio      = 0.0
            Message           = "No scan results"
        }
    }

    $totalPortals = $scanResults.Count
    $transportFailures = 0

    foreach ($item in $scanResults) {
        $res = if ($item.Health) { $item.Health } else { $item }
        if ($res.IsSuccess -eq $false) {
            $st = $res.Status
            if ($st -in "NO DNS/VPN", "TIMEOUT", "REFUSED", "CONN REFUSED", "NET ERROR", "SSL ERROR", "ERR") {
                $transportFailures++
            } elseif ($res.Code -eq "ERR") {
                $transportFailures++
            }
        }
    }

    $failureRatio = if ($totalPortals -gt 0) { $transportFailures / $totalPortals } else { 0.0 }
    $isDisrupted = ($failureRatio -ge $threshold)

    return [PSCustomObject]@{
        IsDisrupted       = $isDisrupted
        TransportFailures = $transportFailures
        TotalPortals      = $totalPortals
        FailureRatio      = $failureRatio
        Message           = if ($isDisrupted) {
            "[!] BLAST RADIUS WARNING: $transportFailures of $totalPortals portals failed network transport simultaneously."
        } else {
            "Normal"
        }
    }
}

# ==============================================================================
# CAPA 3: MOTOR DE ESTADO SOFT VS HARD OUTAGE
# ==============================================================================
function Update-IncidentState {
    param(
        [string]$name,
        [string]$url,
        [PSCustomObject]$healthResult,
        [string]$logFile,
        [switch]$SuppressFailure
    )

    if ($null -eq $global:stats)               { $global:stats = @{} }
    if ($null -eq $global:sessionStats)        { $global:sessionStats = @{} }
    if ($null -eq $global:history)             { $global:history = @{} }
    $global:timeline = $global:history
    if ($null -eq $global:portalCategory)      { $global:portalCategory = @{} }
    if ($null -eq $global:consecutiveFailures) { $global:consecutiveFailures = @{} }
    if ($null -eq $global:isHardOutage)        { $global:isHardOutage = @{} }
    if ($null -eq $global:softOutageStartTime) { $global:softOutageStartTime = @{} }
    if ($null -eq $global:outageStartTime)     { $global:outageStartTime = @{} }

    if (-not $global:stats.ContainsKey($url)) {
        $global:stats[$url] = [PSCustomObject]@{ Success = 0; Failure = 0 }
    }
    if (-not $global:sessionStats.ContainsKey($url)) {
        $global:sessionStats[$url] = [PSCustomObject]@{ Success = 0; Failure = 0 }
    }
    if (-not $global:history.ContainsKey($url)) {
        $global:history[$url] = New-Object 'System.Collections.Generic.Queue[string]' 15
    }
    if (-not $global:consecutiveFailures.ContainsKey($url)) {
        $global:consecutiveFailures[$url] = 0
    }
    if (-not $global:isHardOutage.ContainsKey($url)) {
        $global:isHardOutage[$url] = $false
    }

    # ==========================================================================
    # CASO 1: Portal Respondiendo (ONLINE / DEGRADED / AUTH)
    # ==========================================================================
    if ($healthResult.IsSuccess -eq $true) {
        $global:stats[$url].Success++
        $global:sessionStats[$url].Success++

        $symbol = if ($healthResult.Status -eq "DEGRADED") { "D" } else { "O" }
        Add-TimelineSample -url $url -symbol $symbol

        # Viene de un Hard Outage confirmado?
        if ($global:isHardOutage[$url] -eq $true) {
            $endTime = Get-Date
            $startTime = if ($global:outageStartTime.ContainsKey($url)) { $global:outageStartTime[$url] } else { $endTime }
            $duration = $endTime - $startTime
            $durationSec = [math]::Max(1, [math]::Round($duration.TotalSeconds))
            $durationStr = "{0}m {1}s" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds

            # Registrar resolucion en bitacora oficial
            if ($logFile) {
                $logEntry = "[{0}] [RECOVERED] Portal: {1} | URL: {2} | Downtime: {3} ({4}s)" -f `
                    (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $name, $url, $durationStr, $durationSec
                Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
            }

            $global:resolvedIncidents++
            $global:totalDowntimeSeconds += $durationSec
            $global:outageStartTime.Remove($url)
            $global:isHardOutage[$url] = $false
        }

        # Resetear fallas transitorias silenciosamente (Auto-Healed)
        $global:consecutiveFailures[$url] = 0
        if ($global:softOutageStartTime.ContainsKey($url)) {
            $global:softOutageStartTime.Remove($url)
        }
    }
    # ==========================================================================
    # CASO 2: Falla Suprimida por Blast Radius (Capa 2: Caida de VPN / Ruta)
    # ==========================================================================
    elseif ($SuppressFailure) {
        Add-TimelineSample -url $url -symbol "-"
        # Se congelan los contadores para proteger SLA y no generar alertas
    }
    # ==========================================================================
    # CASO 3: Falla Real de Portal (Evaluacion Soft vs Hard - Capa 3)
    # ==========================================================================
    else {
        $global:stats[$url].Failure++
        $global:sessionStats[$url].Failure++
        Add-TimelineSample -url $url -symbol "X"

        $global:consecutiveFailures[$url]++

        # EVALUACION DE UMBRAL (2 ciclos consecutivos = Hard Outage)
        if ($global:consecutiveFailures[$url] -ge 2) {
            if (-not $global:isHardOutage[$url]) {
                # PROMOCION A HARD OUTAGE
                $global:isHardOutage[$url] = $true

                $startTime = if ($global:softOutageStartTime.ContainsKey($url)) {
                    $global:softOutageStartTime[$url]
                } else {
                    Get-Date
                }
                $global:outageStartTime[$url] = $startTime

                if ($logFile) {
                    $logEntry = "[{0}] [OUTAGE DETECTED] Portal: {1} | URL: {2} | Code: {3} | Reason: Confirmed Hard Outage (2 consecutive cycles)" -f `
                        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $name, $url, $healthResult.Code
                    Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
                }
            }
        } else {
            # CICLO 1: SOFT FAIL (Transitorio en observacion)
            if (-not $global:softOutageStartTime.ContainsKey($url)) {
                $global:softOutageStartTime[$url] = Get-Date
            }
        }
    }
}

function Save-Telemetry {
    param(
        [Alias("csvFile", "path")]
        [string]$csvDbFile,
        [Alias("scanResults", "results")]
        $currentScanResults
    )

    if (-not $global:stats -or $global:stats.Count -eq 0) { return }

    try {
        $exportData = foreach ($url in $global:stats.Keys) {
            $name = $url
            if ($currentScanResults) {
                $matched = $currentScanResults | Where-Object { $_.Url -eq $url } | Select-Object -First 1
                if ($matched) { $name = $matched.Name }
            }
            [PSCustomObject]@{
                Name    = $name
                Url     = $url
                Success = $global:stats[$url].Success
                Failure = $global:stats[$url].Failure
            }
        }
        $exportData | Export-Csv -Path $csvDbFile -NoTypeInformation -Encoding UTF8
    } catch {
        # Escritura silenciosa ante concurrencia
    }
}

function Save-TelemetrySnapshot { Save-Telemetry @args }
function Save-TelemetryDb { Save-Telemetry @args }

# ==============================================================================
# SLA, MTTR & KPIS CALCULATION ENGINES
# ==============================================================================

function Get-FleetSlaPercentage {
    if (-not $global:stats -or $global:stats.Count -eq 0) { return 100.0 }
    $totalSucc = 0
    $totalFail = 0
    foreach ($url in $global:stats.Keys) {
        $totalSucc += $global:stats[$url].Success
        $totalFail += $global:stats[$url].Failure
    }
    $total = $totalSucc + $totalFail
    if ($total -eq 0) { return 100.0 }
    return [math]::Round(($totalSucc / $total) * 100, 1)
}

function Get-SessionSlaPercentage {
    if (-not $global:sessionStats -or $global:sessionStats.Count -eq 0) { return 100.0 }
    $totalSucc = 0
    $totalFail = 0
    foreach ($url in $global:sessionStats.Keys) {
        $totalSucc += $global:sessionStats[$url].Success
        $totalFail += $global:sessionStats[$url].Failure
    }
    $total = $totalSucc + $totalFail
    if ($total -eq 0) { return 100.0 }
    return [math]::Round(($totalSucc / $total) * 100, 1)
}

function Get-FleetMttrFormatted {
    $incidents = if ($global:resolvedIncidents) { $global:resolvedIncidents } else { 0 }
    $downtime  = if ($global:totalDowntimeSeconds) { $global:totalDowntimeSeconds } else { 0 }
    if ($incidents -eq 0 -or $downtime -eq 0) { return "0m 00s" }
    $avgSec = [math]::Round($downtime / $incidents)
    $min = [math]::Floor($avgSec / 60)
    $sec = $avgSec % 60
    return "{0}m {1:D2}s" -f $min, $sec
}

function Get-FleetKpis {

    # FAST PATH: Calculo C# de KPIs de Flota (SLA, MTTR, Outages) en 0.001ms
    if ($global:NativeEngineAvailable) {
        try {
            $k = [FleetProbe.FleetTelemetryEngine]::Instance.ComputeKpis()
            return [PSCustomObject]@{
                HistoricalSla      = $k.HistSla
                HistSla            = $k.HistSla
                SessionSla         = $k.SessSla
                SessSla            = $k.SessSla
                ResolvedIncidents  = $k.Incidents
                Incidents          = $k.Incidents
                FleetMttr          = $k.FleetMttr
                FleetMttrFormatted = $k.FleetMttr
                HardOutagesCount   = $k.HardOutagesCount
                SoftFailsCount     = $k.SoftFailsCount
                OutageDisplay      = $k.OutageDisplay
                OutageColor        = $k.OutageColor
            }
        } catch {}
    }

    $histSla = Get-FleetSlaPercentage
    $sessSla = Get-SessionSlaPercentage
    $mttrStr = Get-FleetMttrFormatted
    $incCount = if ($global:resolvedIncidents) { $global:resolvedIncidents } else { 0 }

    # Conteo de Hard Outages vs Soft Fails (Capa 3)
    $hardOutagesCount = 0
    if ($global:isHardOutage) {
        $hardOutagesCount = ($global:isHardOutage.Values | Where-Object { $_ -eq $true }).Count
    }

    $softFailsCount = 0
    if ($global:consecutiveFailures) {
        $softFailsCount = ($global:consecutiveFailures.Values | Where-Object { $_ -eq 1 }).Count
    }

    $outageDisplay = "$hardOutagesCount"
    if ($softFailsCount -gt 0) {
        $outageDisplay += " ($softFailsCount Soft)"
    }
    $outageColor = if ($hardOutagesCount -gt 0) { "Red" } elseif ($softFailsCount -gt 0) { "Yellow" } else { "Green" }

    return [PSCustomObject]@{
        HistoricalSla      = $histSla
        HistSla            = $histSla
        SessionSla         = $sessSla
        SessSla            = $sessSla
        ResolvedIncidents  = $incCount
        Incidents          = $incCount
        FleetMttr          = $mttrStr
        FleetMttrFormatted = $mttrStr
        ActiveOutagesCount = $hardOutagesCount
        ActiveOutages      = $hardOutagesCount
        SoftFailsCount     = $softFailsCount
        OutageDisplay      = $outageDisplay
        OutageColor        = $outageColor
    }
}
