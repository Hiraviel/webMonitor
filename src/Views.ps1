<#
================================================================================
 MODULE: Views.ps1 (v4.5 Modernized NOC TUI Edition - Pure ASCII Safe Encoding)
 - 100% Pure ASCII source file: Immune to Windows PowerShell 5.1 ANSI/UTF8 issues
 - Calibrated 128-column High-Contrast Console Dashboard
 - Unicode Box-Drawing Borders and SRE Metric Cards via [char] hex runtime
 - Visual Fleet Health Gauge Bar (Real-time Fleet Status)
 - High-Density Sparklines with Unicode Glyphs
 - Full-Screen Diagnostic Modals for Hotkeys [4], [5], [6], [7]
================================================================================
#>

# Definicion de Glifos y Caracteres Box-Drawing via [char] Hexadecimal (Inmune a Encoding ANSI/UTF-8)
$boxH   = [string][char]0x2500  # Horizontal single line
$boxV   = [string][char]0x2502  # Vertical single line
$boxTL  = [string][char]0x250C  # Top-left corner
$boxTR  = [string][char]0x2510  # Top-right corner
$boxBL  = [string][char]0x2514  # Bottom-left corner
$boxBR  = [string][char]0x2518  # Bottom-right corner
$boxLT  = [string][char]0x251C  # Left T-junction
$boxRT  = [string][char]0x2524  # Right T-junction
$boxDH  = [string][char]0x2550  # Double horizontal line
$gDot   = [string][char]0x25CF  # Bullet circle
$gTrg   = [string][char]0x25B2  # Triangle
$gSqr   = [string][char]0x25A0  # Square
$gBlk   = [string][char]0x2588  # Solid block
$gDiaF  = [string][char]0x25C6  # Filled diamond
$gDiaE  = [string][char]0x25C7  # Empty diamond
$gDiaT  = [string][char]0x25C8  # Target diamond
$gMidD  = [string][char]0x00B7  # Middle dot
$gCross = [string][char]0x2716  # Cross

# Inicializacion de divisores globales a 128 columnas exactas
if ($null -eq $global:mainDivider) { $global:mainDivider = $boxDH * 128 }
if ($null -eq $global:subDivider)  { $global:subDivider  = $boxH * 128 }

function Render-MainHeader {
    param(
        [Alias("cadenceSec", "cadence", "interval")]
        [int]$intervalSeconds = 120,

        [Alias("timestamp", "lastCheckTime")]
        [string]$lastCheck = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),

        [Alias("scanDuration", "durationSec", "durationMs", "lastScanDurationSec", "lastScanDuration")]
        [int]$scanDurationMs = 0,

        [Alias("azure")]
        $azureStatus = $null,

        [Alias("sase", "prismaStatus")]
        $saseStatus = $null,

        [Alias("egress", "probeStatus", "egressHealth", "probeHealth")]
        $egressStatus = $null,

        [Alias("lastSnapshot", "dbSnapshot")]
        [string]$csvLastSnapshot = "",

        [Alias("keepAlive")]
        [string]$keepAliveStatus = "ACTIVE: Anti-Sleep ON",

        [Alias("fleetKpis")]
        $kpis = $null,

        $blastRadius = $null
    )

    # In-Place Zero-Flicker Screen Refresh
    try {
        [Console]::CursorVisible = $false
        [Console]::SetCursorPosition(0, 0)
    } catch {
        Clear-Host
    }

    # Borde superior estilizado a 128 columnas exactas
    Write-Host "$boxTL$boxH PREVENTIVE PORTAL MONITOR " -ForegroundColor Cyan -NoNewline
    Write-Host ($boxH * 4) -ForegroundColor DarkGray -NoNewline
    Write-Host " [ IT & SUPPORT NOC EDITION v4.5 ] " -ForegroundColor White -NoNewline
    Write-Host ($boxH * 59) -ForegroundColor DarkGray -NoNewline
    Write-Host $boxTR -ForegroundColor DarkGray

    # Linea 1: Telemetria de Barrido y Enlace de Salida (Capa 1 Egress)
    $egressText = "ONLINE"
    $egressColor = "Green"
    if ($egressStatus) {
        if ($egressStatus.IsHealthy -or $null -eq $egressStatus.IsHealthy) {
            $egressText  = if ($egressStatus.Status) { $egressStatus.Status } elseif ($egressStatus.StatusText) { $egressStatus.StatusText } else { "ONLINE" }
            $egressColor = if ($egressStatus.Color)  { $egressStatus.Color }  else { "Green" }
        } else {
            $egressText  = if ($egressStatus.Status) { $egressStatus.Status } elseif ($egressStatus.StatusText) { $egressStatus.StatusText } else { "OFFLINE" }
            $egressColor = if ($egressStatus.Color)  { $egressStatus.Color }  else { "Red" }
        }
    }
    $egressIcon  = if ($egressColor -eq "Green") { "$gDot " } else { "$gCross " }
    $egressFull  = "$egressIcon$egressText"

    $engLabel = if ($global:NativeEngineAvailable) { "C# Nat" } else { "Runspace" }
    $memUsageMb = [int][Math]::Round(([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB), 0)
    $durBadge = if ($scanDurationMs -ge 1000) {
        "{0:N1}s ({1}|{2}MB)" -f ($scanDurationMs / 1000.0), $engLabel, $memUsageMb
    } elseif ($scanDurationMs -gt 0) {
        "{0}ms ({1}|{2}MB)" -f $scanDurationMs, $engLabel, $memUsageMb
    } else {
        "<1ms ({0}|{1}MB)" -f $engLabel, $memUsageMb
    }

    Write-Host "$boxV  Last Scan: " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-19}" -f $lastCheck) -ForegroundColor White -NoNewline
    Write-Host " $boxV Cadence: " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-5}" -f "${intervalSeconds}s") -ForegroundColor White -NoNewline
    Write-Host " $boxV Duration: " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-18}" -f $durBadge) -ForegroundColor Green -NoNewline
    Write-Host " $boxV Egress: " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-34}" -f $egressFull) -ForegroundColor $egressColor -NoNewline
    Write-Host " $boxV" -ForegroundColor DarkGray

    # Linea 2: Feeds Cloud Externos (Azure Infrastructure + SASE / Prisma)
    $azText    = if ($azureStatus -and $azureStatus.Status) { $azureStatus.Status } else { "[ AZURE CLOUD: OPERATIONAL ]" }
    $azColor   = if ($azureStatus -and $azureStatus.Color)  { $azureStatus.Color }  else { "Green" }
    $saseText  = if ($saseStatus -and $saseStatus.Status)   { $saseStatus.Status }  else { "[ SASE / PRISMA: OPERATIONAL ]" }
    $saseColor = if ($saseStatus -and $saseStatus.Color)   { $saseStatus.Color }   else { "Green" }

    Write-Host "$boxV  Infrastructure: " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-44}" -f $azText) -ForegroundColor $azColor -NoNewline
    Write-Host " $boxV SASE / Gateway: " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-44}" -f $saseText) -ForegroundColor $saseColor -NoNewline
    Write-Host " $boxV" -ForegroundColor DarkGray

    # Linea 3: Separador de tarjetas de metricas
    Write-Host $boxLT -ForegroundColor DarkGray -NoNewline
    Write-Host ($boxH * 126) -ForegroundColor DarkGray -NoNewline
    Write-Host $boxRT -ForegroundColor DarkGray

    # Metricas y KPIs de Flota (Capa 3)
    $actualKpis = if ($kpis) { $kpis } elseif (Get-Command Get-FleetKpis -ErrorAction SilentlyContinue) { Get-FleetKpis } else { $null }

    $histSla       = if ($actualKpis -and $actualKpis.HistSla) { "{0:N2}%" -f $actualKpis.HistSla } else { "100.00%" }
    $sessSla       = if ($actualKpis -and $actualKpis.SessSla) { "{0:N2}%" -f $actualKpis.SessSla } else { "100.00%" }
    $mttrStr       = if ($actualKpis -and $actualKpis.FleetMttr) { $actualKpis.FleetMttr } else { "0m 00s" }
    $incCount      = if ($actualKpis -and $null -ne $actualKpis.Incidents) { [string]$actualKpis.Incidents } elseif ($global:resolvedIncidents) { [string]$global:resolvedIncidents } else { "0" }
    $outageDisplay = if ($actualKpis -and $actualKpis.OutageDisplay) { $actualKpis.OutageDisplay } else { "0 (HEALTHY)" }
    $outageColor   = if ($actualKpis -and $actualKpis.OutageColor) { $actualKpis.OutageColor } else { "Green" }

    # Lineas 4, 5, 6, 7: Cuadricula TUI de Stat Cards (5 tarjetas perfectamente calibradas)
    $cTop = ($boxTL + ($boxH * 14) + $boxTR) + "  " + ($boxTL + ($boxH * 14) + $boxTR) + "  " + ($boxTL + ($boxH * 14) + $boxTR) + "  " + ($boxTL + ($boxH * 14) + $boxTR) + "  " + ($boxTL + ($boxH * 16) + $boxTR)
    $cBot = ($boxBL + ($boxH * 14) + $boxBR) + "  " + ($boxBL + ($boxH * 14) + $boxBR) + "  " + ($boxBL + ($boxH * 14) + $boxBR) + "  " + ($boxBL + ($boxH * 14) + $boxBR) + "  " + ($boxBL + ($boxH * 16) + $boxBR)

    Write-Host "$boxV  $cTop" -ForegroundColor DarkGray -NoNewline
    Write-Host (" " * 33) -NoNewline
    Write-Host " $boxV" -ForegroundColor DarkGray

    Write-Host "$boxV  " -ForegroundColor DarkGray -NoNewline
    Write-Host "$boxV HIST SLA     $boxV  $boxV SESSION SLA  $boxV  $boxV FLEET MTTR   $boxV  $boxV INCIDENTS    $boxV  $boxV ACTIVE OUTAGES $boxV" -ForegroundColor DarkGray -NoNewline
    Write-Host (" " * 33) -NoNewline
    Write-Host " $boxV" -ForegroundColor DarkGray

    Write-Host "$boxV  $boxV " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-12}" -f $histSla) -ForegroundColor Cyan -NoNewline
    Write-Host " $boxV  $boxV " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-12}" -f $sessSla) -ForegroundColor Green -NoNewline
    Write-Host " $boxV  $boxV " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-12}" -f $mttrStr) -ForegroundColor Magenta -NoNewline
    Write-Host " $boxV  $boxV " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-12}" -f $incCount) -ForegroundColor Yellow -NoNewline
    Write-Host " $boxV  $boxV " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-14}" -f $outageDisplay) -ForegroundColor $outageColor -NoNewline
    Write-Host " $boxV" -ForegroundColor DarkGray -NoNewline
    Write-Host (" " * 33) -NoNewline
    Write-Host " $boxV" -ForegroundColor DarkGray

    Write-Host "$boxV  $cBot" -ForegroundColor DarkGray -NoNewline
    Write-Host (" " * 33) -NoNewline
    Write-Host " $boxV" -ForegroundColor DarkGray

    # Linea 8: Barra Visual de Salud de Flota (Fleet Health Gauge Bar)
    $totPortals = 0; $upPortals = 0; $degPortals = 0; $outPortals = 0
    if ($global:history) {
        $totPortals = $global:history.Keys.Count
        foreach ($u in $global:history.Keys) {
            $list = $global:history[$u]
            if ($list -and $list.Count -gt 0) {
                $lastVal = $list[$list.Count - 1]
                if ($lastVal -eq "O") { $upPortals++ }
                elseif ($lastVal -eq "D") { $degPortals++ }
                elseif ($lastVal -eq "X") { $outPortals++ }
            }
        }
    }

    $barWidth  = 20
    $filledUp  = if ($totPortals -gt 0) { [Math]::Round(($upPortals / $totPortals) * $barWidth) } else { $barWidth }
    $filledDeg = if ($totPortals -gt 0) { [Math]::Round(($degPortals / $totPortals) * $barWidth) } else { 0 }
    $filledOut = if ($totPortals -gt 0) { [Math]::Max(0, $barWidth - $filledUp - $filledDeg) } else { 0 }

    # FAST PATH: Win32 Double-Buffering Render (0.01ms - Cero Write-Host)
    if ($global:NativeEngineAvailable) {
        $c = [FleetProbe.FastCanvas]::Instance
        for ($r = 0; $r -le 9; $r++) { $c.ClearRow($r) }

        # Fila 0: Borde Superior
        $c.WriteSpan(0, 0, "$boxTL$boxH PREVENTIVE PORTAL MONITOR ", "Cyan", "Black")
        $c.WriteSpan(32, 0, ($boxH * 4), "DarkGray", "Black")
        $c.WriteSpan(36, 0, " [ IT & SUPPORT NOC EDITION v4.5 ] ", "White", "Black")
        $c.WriteSpan(71, 0, ($boxH * 56), "DarkGray", "Black")
        $c.WriteSpan(127, 0, $boxTR, "DarkGray", "Black")

        # Fila 1: Telemetria de Barrido y Egress
        $c.WriteSpan(0, 1, "$boxV  Last Scan: ", "DarkGray", "Black")
        $c.WriteSpan(14, 1, ("{0,-19}" -f $lastCheck), "White", "Black")
        $c.WriteSpan(33, 1, " $boxV Cadence: ", "DarkGray", "Black")
        $c.WriteSpan(45, 1, ("{0,-5}" -f "${intervalSeconds}s"), "White", "Black")
        $c.WriteSpan(50, 1, " $boxV Duration: ", "DarkGray", "Black")
        $c.WriteSpan(63, 1, ("{0,-18}" -f $durBadge), "Green", "Black")
        $c.WriteSpan(81, 1, " $boxV Egress: ", "DarkGray", "Black")
        $c.WriteSpan(92, 1, $egressIcon, $egressColor, "Black")
        $c.WriteSpan(94, 1, ("{0,-32}" -f $egressText), $egressColor, "Black")
        $c.WriteSpan(127, 1, $boxV, "DarkGray", "Black")

        # Fila 2: Feeds Cloud (Azure + SASE)
        $c.WriteSpan(0, 2, "$boxV  Infrastructure: ", "DarkGray", "Black")
        $c.WriteSpan(20, 2, ("{0,-44}" -f $azText), $azColor, "Black")
        $c.WriteSpan(64, 2, " $boxV SASE / Gateway: ", "DarkGray", "Black")
        $c.WriteSpan(83, 2, ("{0,-44}" -f $saseText), $saseColor, "Black")
        $c.WriteSpan(127, 2, $boxV, "DarkGray", "Black")

        # Fila 3: Separador de tarjetas
        $c.WriteSpan(0, 3, $boxLT, "DarkGray", "Black")
        $c.WriteSpan(1, 3, ($boxH * 126), "DarkGray", "Black")
        $c.WriteSpan(127, 3, $boxRT, "DarkGray", "Black")

        # Fila 4: Borde superior de Stat Cards
        $c.WriteSpan(0, 4, "$boxV  $cTop", "DarkGray", "Black")
        $c.WriteSpan(94, 4, (" " * 33), "DarkGray", "Black")
        $c.WriteSpan(127, 4, $boxV, "DarkGray", "Black")

        # Fila 5: Titulos de Stat Cards
        $c.WriteSpan(0, 5, "$boxV  $boxV HIST SLA     $boxV  $boxV SESSION SLA  $boxV  $boxV FLEET MTTR   $boxV  $boxV INCIDENTS    $boxV  $boxV ACTIVE OUTAGES $boxV", "DarkGray", "Black")
        $c.WriteSpan(94, 5, (" " * 33), "DarkGray", "Black")
        $c.WriteSpan(127, 5, $boxV, "DarkGray", "Black")

        # Fila 6: Metricas de Stat Cards
        $c.WriteSpan(0, 6, "$boxV  $boxV ", "DarkGray", "Black")
        $c.WriteSpan(5, 6, ("{0,-12}" -f $histSla), "Cyan", "Black")
        $c.WriteSpan(17, 6, " $boxV  $boxV ", "DarkGray", "Black")
        $c.WriteSpan(24, 6, ("{0,-12}" -f $sessSla), "Green", "Black")
        $c.WriteSpan(36, 6, " $boxV  $boxV ", "DarkGray", "Black")
        $c.WriteSpan(43, 6, ("{0,-12}" -f $mttrStr), "Magenta", "Black")
        $c.WriteSpan(55, 6, " $boxV  $boxV ", "DarkGray", "Black")
        $c.WriteSpan(62, 6, ("{0,-12}" -f $incCount), "Yellow", "Black")
        $c.WriteSpan(74, 6, " $boxV  $boxV ", "DarkGray", "Black")
        $c.WriteSpan(81, 6, ("{0,-14}" -f $outageDisplay), $outageColor, "Black")
        $c.WriteSpan(95, 6, " $boxV", "DarkGray", "Black")
        $c.WriteSpan(97, 6, (" " * 30), "DarkGray", "Black")
        $c.WriteSpan(127, 6, $boxV, "DarkGray", "Black")

        # Fila 7: Borde inferior de Stat Cards
        $c.WriteSpan(0, 7, "$boxV  $cBot", "DarkGray", "Black")
        $c.WriteSpan(94, 7, (" " * 33), "DarkGray", "Black")
        $c.WriteSpan(127, 7, $boxV, "DarkGray", "Black")

        # Fila 8: Fleet Health Gauge Bar
        $c.WriteSpan(0, 8, "$boxV  Fleet Health : [", "DarkGray", "Black")
        $c.WriteSpan(19, 8, ($gBlk * $filledUp), "Green", "Black")
        $c.WriteSpan(19 + $filledUp, 8, ($gBlk * $filledDeg), "Yellow", "Black")
        $c.WriteSpan(19 + $filledUp + $filledDeg, 8, ($gBlk * $filledOut), "Red", "Black")
        $c.WriteSpan(39, 8, "] ", "DarkGray", "Black")
        $c.WriteSpan(41, 8, ("{0,2} Online" -f $upPortals), "Green", "Black")
        $c.WriteSpan(51, 8, " / ", "DarkGray", "Black")
        $c.WriteSpan(54, 8, ("{0} Soft" -f $degPortals), "Yellow", "Black")
        $c.WriteSpan(61, 8, " / ", "DarkGray", "Black")
        $c.WriteSpan(64, 8, ("{0} Outage" -f $outPortals), "Red", "Black")
        $c.WriteSpan(73, 8, " $boxV Categories: ", "DarkGray", "Black")
        $c.WriteSpan(88, 8, "$gDiaT IT Core (DarkYellow)  ", "DarkYellow", "Black")
        $c.WriteSpan(114, 8, "$gDiaE Support (Cyan)", "Cyan", "Black")
        $c.WriteSpan(127, 8, $boxV, "DarkGray", "Black")

        # Fila 9: Borde inferior del encabezado
        $c.WriteSpan(0, 9, $boxBL, "DarkGray", "Black")
        $c.WriteSpan(1, 9, ($boxH * 126), "DarkGray", "Black")
        $c.WriteSpan(127, 9, $boxBR, "DarkGray", "Black")

        $flushed = $c.FlushRegion(0, 9)
        if ($flushed) {
            try { [Console]::SetCursorPosition(0, 10) } catch {}
            return
        }
    }


    Write-Host "$boxV  Fleet Health : [" -ForegroundColor DarkGray -NoNewline
    Write-Host ($gBlk * $filledUp) -ForegroundColor Green -NoNewline
    Write-Host ($gBlk * $filledDeg) -ForegroundColor Yellow -NoNewline
    Write-Host ($gBlk * $filledOut) -ForegroundColor Red -NoNewline
    Write-Host "] " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,2} Online" -f $upPortals) -ForegroundColor Green -NoNewline
    Write-Host " / " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0} Soft" -f $degPortals) -ForegroundColor Yellow -NoNewline
    Write-Host " / " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0} Outage" -f $outPortals) -ForegroundColor Red -NoNewline
    Write-Host " $boxV Categories: " -ForegroundColor DarkGray -NoNewline
    Write-Host "$gDiaT IT Core (DarkYellow)  " -ForegroundColor DarkYellow -NoNewline
    Write-Host "$gDiaE Support (Cyan)" -ForegroundColor Cyan -NoNewline
    Write-Host " " -NoNewline
    Write-Host " $boxV" -ForegroundColor DarkGray

    # Borde inferior del encabezado principal
    Write-Host $boxBL -ForegroundColor DarkGray -NoNewline
    Write-Host ($boxH * 126) -ForegroundColor DarkGray -NoNewline
    Write-Host $boxBR -ForegroundColor DarkGray
}

function Render-Header { Render-MainHeader @args }

function Render-TableHeader {
    param([int]$rowIndex = -1)
    if ($global:NativeEngineAvailable -and $rowIndex -ge 0) {
        $c = [FleetProbe.FastCanvas]::Instance
        $c.ClearRow($rowIndex)
        $c.ClearRow($rowIndex + 1)
        $headerStr = "{0,-14}{1,-22}{2,-8}{3,-10}{4,-14}{5,-15}{6,-9}{7}" -f `
            "STATUS", "PORTAL", "CODE", "LATENCY", "TIMELINE(10)", "VERIF(OK|NO)", "UPTIME %", "URL TARGET"
        $c.WriteSpan(0, $rowIndex, $headerStr, "Yellow", "Black")
        $c.WriteSpan(0, $rowIndex + 1, $global:subDivider, "DarkGray", "Black")
        $flushed = $c.FlushRegion($rowIndex, $rowIndex + 1)
        if ($flushed) { return }
    }
    Write-Host ("{0,-14}{1,-22}{2,-8}{3,-10}{4,-14}{5,-15}{6,-9}{7}" -f `
        "STATUS", "PORTAL", "CODE", "LATENCY", "TIMELINE(10)", "VERIF(OK|NO)", "UPTIME %", "URL TARGET") -ForegroundColor Yellow
    Write-Host $global:subDivider -ForegroundColor DarkGray
}

function Render-PortalRow {
    param(
        [PSCustomObject]$res,
        $categoryColor = "DarkYellow",
        [int]$successCount = 0,
        [int]$failureCount = 0,
        [double]$uptimePct = 100.0,
        $historyList = @(),

        [string]$name = "",
        [string]$url = "",
        [string]$tag = "",
        [switch]$IsBlastRadiusDisrupted,
        [int]$rowIndex = -1
    )

    # 1. Resolver nombre y URL desde $res si no vienen explicitos
    $targetName = if (-not [string]::IsNullOrWhiteSpace($name)) { $name } elseif ($res.Name) { $res.Name } else { "Portal" }
    $targetUrl  = if (-not [string]::IsNullOrWhiteSpace($url))  { $url }  elseif ($res.Url)  { $res.Url }  else { "" }

    # 2. Badge de Estado con Glifos SRE de ancho unico (14 caracteres exactos)
    $cleanStatus = $res.Status
    if ($cleanStatus -eq "CONN REFUSED") { $cleanStatus = "REFUSED" }

    $badge = switch ($cleanStatus) {
        "ONLINE"     { "$gDot ONLINE     " }
        "AUTH/SSO"   { "$gDiaF AUTH/SSO   " }
        "AUTH REQ"   { "$gDiaE AUTH REQ   " }
        "DEGRADED"   { "$gTrg DEGRADED   " }
        "BAD REQ"    { "$gTrg BAD REQ    " }
        "TIMEOUT"    { "$gSqr TIMEOUT    " }
        "REFUSED"    { "$gSqr REFUSED    " }
        "NO DNS/VPN" { "$gSqr NO DNS/VPN " }
        "SRV ERROR"  { "$gSqr SRV ERROR  " }
        "NOT FOUND"  { "$gSqr NOT FOUND  " }
        default      { "$gSqr {0,-10}" -f $cleanStatus }
    }
    if ($badge.Length -gt 14) { $badge = $badge.Substring(0, 14) }

    # 3. Color de Severidad (Capa 2 y Capa 3: Soft Fail vs Hard Outage)
    $rowColor = $res.Color
    if ($res.IsSuccess -eq $false) {
        if ($IsBlastRadiusDisrupted) {
            $rowColor = "DarkGray"
            $badge    = "- FROZEN     "
        } else {
            $consec = if ($global:consecutiveFailures -and $targetUrl -and $global:consecutiveFailures.ContainsKey($targetUrl)) {
                $global:consecutiveFailures[$targetUrl]
            } else { 0 }

            if ($consec -le 1) {
                $rowColor = "Yellow" # Soft Fail (Ciclo 1)
                $badge    = "$gTrg SOFT FAIL  "
            } else {
                $rowColor = "Red"    # Hard Outage (Ciclo 2+)
                $badge    = "$gSqr HARD OUTAGE"
            }
        }
    }

    # 4. Nombre con icono de categoria (22 caracteres exactos)
    $catIcon = if ($categoryColor -eq "Cyan" -or $tag -eq "S") { "$gDiaE " } else { "$gDiaT " }
    $displayName = $catIcon + $targetName
    if ($displayName.Length -gt 21) {
        $displayName = $displayName.Substring(0, 18) + "..."
    }

    # Color de nombre segun categoria (IT Core en DarkYellow, Support en Cyan)
    $nameColor = if ($categoryColor) { $categoryColor } elseif ($tag -eq "S") { "Cyan" } else { "DarkYellow" }

    # 5. Latencia formateada con umbrales de color (10 caracteres)
    $latencyDisplay = if ($res.LatencyMs -ge 0) { "{0}ms" -f $res.LatencyMs } else { "---" }
    $latColor = if ($res.LatencyMs -lt 0) { "DarkGray" }
                elseif ($res.LatencyMs -lt 800) { "DarkGreen" }
                elseif ($res.LatencyMs -le 3500) { "Yellow" }
                else { "Red" }

    # 6. Sparkline de 10 muestras con densidad grafica (14 caracteres: 10 glifos + 4 espacios)
    $samples = if ($historyList) { $historyList } elseif ($global:history -and $targetUrl -and $global:history.ContainsKey($targetUrl)) { $global:history[$targetUrl] } else { @() }
    $recent = @($samples)
    if ($recent.Count -gt 10) {
        $recent = $recent[($recent.Count - 10)..($recent.Count - 1)]
    }
    $padCount = [Math]::Max(0, 10 - $recent.Count)

    # 7. Verificaciones OK | NO (15 caracteres)
    $verifStr = "{0} | {1}" -f $successCount, $failureCount

    # 8. Uptime % (9 caracteres)
    $uptimeStr = "{0,5:N1}%   " -f $uptimePct
    $upColor = if ($uptimePct -ge 99.0) { "Green" } elseif ($uptimePct -ge 95.0) { "Yellow" } else { "Red" }

    # 9. URL truncada a 36 caracteres exactos
    $urlDisplay = $targetUrl
    if ($urlDisplay.Length -gt 36) {
        $urlDisplay = $urlDisplay.Substring(0, 33) + "..."
    }

    # RUTA A: DOUBLE-BUFFERING DIRECTO EN MEMORIA DE VIDEO WIN32 (<0.01ms)
    if ($global:NativeEngineAvailable -and $rowIndex -ge 0) {
        $c = [FleetProbe.FastCanvas]::Instance
        $c.ClearRow($rowIndex)
        $c.WriteSpan(0,  $rowIndex, ("{0,-14}" -f $badge), $rowColor, "Black")
        $c.WriteSpan(14, $rowIndex, ("{0,-22}" -f $displayName), $nameColor, "Black")
        $c.WriteSpan(36, $rowIndex, ("{0,-8}"  -f $res.Code), $rowColor, "Black")
        $c.WriteSpan(44, $rowIndex, ("{0,-10}" -f $latencyDisplay), $latColor, "Black")

        # Sparklines de 10 glifos en buffer de memoria
        $x = 54
        for ($i = 0; $i -lt $padCount; $i++) {
            $c.WriteSpan($x, $rowIndex, $gMidD, "DarkGray", "Black")
            $x++
        }
        foreach ($sym in $recent) {
            switch ($sym) {
                "O" { $c.WriteSpan($x, $rowIndex, $gSqr, "Green", "Black") }
                "D" { $c.WriteSpan($x, $rowIndex, $gTrg, "Yellow", "Black") }
                "X" { $c.WriteSpan($x, $rowIndex, $gSqr, "Red", "Black") }
                "-" { $c.WriteSpan($x, $rowIndex, $gMidD, "DarkGray", "Black") }
                default { $c.WriteSpan($x, $rowIndex, $gMidD, "DarkGray", "Black") }
            }
            $x++
        }
        $c.WriteSpan(64, $rowIndex, "    ", "Black", "Black")
        $c.WriteSpan(68, $rowIndex, ("{0,-15}" -f $verifStr), "DarkGray", "Black")
        $c.WriteSpan(83, $rowIndex, ("{0,-9}"  -f $uptimeStr), $upColor, "Black")
        $c.WriteSpan(92, $rowIndex, ("{0,-36}" -f $urlDisplay), "Gray", "Black")

        # Volcado directo de 256 bytes al buffer de video de la consola (<0.01 ms)
        $flushed = $c.FlushRow($rowIndex)
        if ($flushed) { return }
    }

    # RUTA B: FALLBACK ESTANDAR EN CASO DE CONSOLA REDIRIGIDA
    Write-Host ("{0,-14}" -f $badge) -ForegroundColor $rowColor -NoNewline
    Write-Host ("{0,-22}" -f $displayName) -ForegroundColor $nameColor -NoNewline
    Write-Host ("{0,-8}"  -f $res.Code) -ForegroundColor $rowColor -NoNewline
    Write-Host ("{0,-10}" -f $latencyDisplay) -ForegroundColor $latColor -NoNewline

    for ($i = 0; $i -lt $padCount; $i++) {
        Write-Host $gMidD -ForegroundColor DarkGray -NoNewline
    }
    foreach ($sym in $recent) {
        switch ($sym) {
            "O" { Write-Host $gSqr -ForegroundColor Green -NoNewline }
            "D" { Write-Host $gTrg -ForegroundColor Yellow -NoNewline }
            "X" { Write-Host $gSqr -ForegroundColor Red -NoNewline }
            "-" { Write-Host $gMidD -ForegroundColor DarkGray -NoNewline }
            default { Write-Host $gMidD -ForegroundColor DarkGray -NoNewline }
        }
    }
    Write-Host "    " -NoNewline

    Write-Host ("{0,-15}" -f $verifStr) -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,-9}"  -f $uptimeStr) -ForegroundColor $upColor -NoNewline
    Write-Host ("{0,-36}" -f $urlDisplay) -ForegroundColor Gray
}

function Render-TableFooter {
    param(
        [PSCustomObject]$blastRadius
    )
    Write-Host $global:subDivider -ForegroundColor DarkGray
    if ($blastRadius -and $blastRadius.IsDisrupted) {
        Write-Host (" [!] BLAST RADIUS WARNING: {0} of {1} portals ({2:P0}) failed network transport simultaneously." -f `
            $blastRadius.TransportFailures, $blastRadius.TotalPortals, $blastRadius.FailureRatio) -ForegroundColor Yellow
        Write-Host " [!] Probe Route/VPN Disruption detected. SLA & Outages FROZEN for this cycle to prevent false incidents." -ForegroundColor DarkYellow
        Write-Host $global:subDivider -ForegroundColor DarkGray
    }
}

# ==============================================================================
# MODALES DIAGNOSTICOS DE PANTALLA COMPLETA (HOTKEYS [4], [5], [6], [7])
# ==============================================================================

function Show-OutagesLogModal {
    param([string]$logFile = (Join-Path $scriptDir "outages.log"))
    Clear-Host
    Write-Host $global:mainDivider -ForegroundColor Red
    Write-Host " OUTAGES & INCIDENT AUDIT TRAIL LOG (outages.log)" -ForegroundColor White
    Write-Host $global:mainDivider -ForegroundColor Red
    Write-Host ""
    if (Test-Path $logFile) {
        Get-Content $logFile -Tail 30 | ForEach-Object {
            if ($_ -match "\[RECOVERED\]") {
                Write-Host $_ -ForegroundColor Green
            } elseif ($_ -match "\[OUTAGE DETECTED\]") {
                Write-Host $_ -ForegroundColor Red
            } elseif ($_ -match "\[BLAST RADIUS\]") {
                Write-Host $_ -ForegroundColor Yellow
            } else {
                Write-Host $_ -ForegroundColor Gray
            }
        }
    } else {
        Write-Host " No outages recorded yet. Clean SLA slate!" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host $global:subDivider -ForegroundColor DarkGray
    Write-Host " Presiona cualquier tecla para volver al monitor..." -ForegroundColor Yellow
    [Console]::ReadKey($true) | Out-Null
}

function Show-CsvDatabaseModal {
    param([string]$csvFile = (Join-Path $scriptDir "history.csv"))
    Clear-Host
    Write-Host $global:mainDivider -ForegroundColor Cyan
    Write-Host " TELEMETRY DATABASE SNAPSHOT (history.csv)" -ForegroundColor White
    Write-Host $global:mainDivider -ForegroundColor Cyan
    Write-Host ""
    if (Test-Path $csvFile) {
        Get-Content $csvFile -Tail 25 | ForEach-Object {
            Write-Host $_ -ForegroundColor DarkCyan
        }
    } else {
        Write-Host " No CSV snapshot generated yet." -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host $global:subDivider -ForegroundColor DarkGray
    Write-Host " Presiona cualquier tecla para volver al monitor..." -ForegroundColor Yellow
    [Console]::ReadKey($true) | Out-Null
}

function Show-SasePrismaModal {
    param([PSCustomObject]$saseStatus)
    Clear-Host
    Write-Host $global:mainDivider -ForegroundColor Cyan
    Write-Host " SASE & GATEWAY INFRASTRUCTURE HEALTH DASHBOARD" -ForegroundColor White
    Write-Host $global:mainDivider -ForegroundColor Cyan
    Write-Host ""
    $stText = if ($saseStatus -and $saseStatus.Status) { $saseStatus.Status } else { "[ SASE: OPERATIONAL ]" }
    $stCol  = if ($saseStatus -and $saseStatus.Color)  { $saseStatus.Color }  else { "Green" }
    Write-Host " Status Resumen : " -ForegroundColor Gray -NoNewline
    Write-Host $stText -ForegroundColor $stCol
    Write-Host ""
    if ($saseStatus -and $saseStatus.Details) {
        Write-Host " Componentes Reportados:" -ForegroundColor Yellow
        $saseStatus.Details | ForEach-Object {
            Write-Host ("   * {0}" -f $_) -ForegroundColor Gray
        }
    } else {
        Write-Host " Todos los tuneles y gateways SASE se encuentran operando normalmente." -ForegroundColor Green
    }
    Write-Host ""
    Write-Host $global:subDivider -ForegroundColor DarkGray
    Write-Host " Presiona cualquier tecla para volver al monitor..." -ForegroundColor Yellow
    [Console]::ReadKey($true) | Out-Null
}

function Show-NocMetricsModal {
    Clear-Host
    Write-Host $global:mainDivider -ForegroundColor Green
    Write-Host " FLEET NOC METRICS & MTTR BREAKDOWN REPORT" -ForegroundColor White
    Write-Host $global:mainDivider -ForegroundColor Green
    Write-Host ""
    $histSla = if (Get-Command Get-FleetSlaPercentage -ErrorAction SilentlyContinue) { Get-FleetSlaPercentage } else { 100.0 }
    $sessSla = if (Get-Command Get-SessionSlaPercentage -ErrorAction SilentlyContinue) { Get-SessionSlaPercentage } else { 100.0 }
    $mttrVal = if (Get-Command Get-FleetMttrFormatted -ErrorAction SilentlyContinue) { Get-FleetMttrFormatted } else { "0m 00s" }

    Write-Host (" Fleet Historical SLA : {0:N2}%" -f $histSla) -ForegroundColor Cyan
    Write-Host (" Session Shift SLA    : {0:N2}%" -f $sessSla) -ForegroundColor Green
    Write-Host (" Resolved Incidents   : {0}" -f $global:resolvedIncidents) -ForegroundColor Yellow
    Write-Host (" Fleet Global MTTR    : {0}" -f $mttrVal) -ForegroundColor Magenta
    Write-Host ""
    Write-Host ("{0,-36}{1,-12}{2,-12}{3,-12}" -f "PORTAL TARGET", "SUCCESS", "FAILURE", "UPTIME %") -ForegroundColor Yellow
    Write-Host ($boxH * 72) -ForegroundColor DarkGray
    if ($global:stats) {
        foreach ($url in $global:stats.Keys) {
            $st = $global:stats[$url]
            $tot = $st.Success + $st.Failure
            $pct = if ($tot -gt 0) { ($st.Success / $tot) * 100 } else { 100.0 }
            $dispUrl = if ($url.Length -gt 34) { $url.Substring(0, 31) + "..." } else { $url }
            Write-Host ("{0,-36}{1,-12}{2,-12}{3,-10:N1}%" -f $dispUrl, $st.Success, $st.Failure, $pct) -ForegroundColor Gray
        }
    }
    Write-Host ""
    Write-Host $global:subDivider -ForegroundColor DarkGray
    Write-Host " Presiona cualquier tecla para volver al monitor..." -ForegroundColor Yellow
    [Console]::ReadKey($true) | Out-Null
}

# Alias de compatibilidad para llamadas directas desde monitor.ps1
function Show-PaloAltoDetails   { Show-SasePrismaModal @args }
function Show-NocMetricsDetails { Show-NocMetricsModal @args }
