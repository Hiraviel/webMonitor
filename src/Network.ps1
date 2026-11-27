<#
================================================================================
 MODULE: Network.ps1 (v4.4.1 Egress Canary Edition)
 - Strict HTTP WebRequest GET with 3.5s timeout (prevents hanging sockets)
 - Diagnostic classification of transport vs server vs functional auth codes
 - Safe Exception Inspection (resilient to Windows Lock Screen / NIC sleep)
 - Probe Egress Verification (Loopback + Anycast DNS Canary with TCP fallback)
 - External Cloud Health checks: Azure RSS & Palo Alto / Prisma SASE
================================================================================
#>

# Configuracion de protocolos criptograficos
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
[System.Net.ServicePointManager]::Expect100Continue = $false

function Invoke-RestGetWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$url,
        [int]$timeoutMs = 3500
    )
    $req = $null
    $res = $null
    $reader = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = $timeoutMs
        $req.ReadWriteTimeout = $timeoutMs
        $req.AllowAutoRedirect = $true
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) IT-NOC-Monitor/4.3"

        $res = $req.GetResponse()
        $stream = $res.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { try { $reader.Close(); $reader.Dispose() } catch {} }
        if ($null -ne $res)    { try { $res.Close(); $res.Dispose() } catch {} }
    }
}

function Get-PaloAltoCloudHealth {
    param([int]$timeoutMs = 3500)
    try {
        $paloUrl = "https://status.paloaltonetworks.com/api/v2/summary.json"
        $json = Invoke-RestGetWithTimeout -url $paloUrl -timeoutMs $timeoutMs
        $data = $json | ConvertFrom-Json

        # 1. Filtro estricto: Solo componentes directos de SASE / Conectividad / VPN
        $saseComponents = $data.components | Where-Object { 
            $_.name -match "Prisma Access|GlobalProtect|Strata Cloud Manager|Mobile Users|Remote Networks|Cloud Identity" 
        }

        # 2. Verificar incidentes activos no resueltos relacionados a SASE
        $activeSaseIncidents = $data.incidents | Where-Object { 
            [string]::IsNullOrWhiteSpace($_.resolved_at) -and $_.status -ne "resolved" -and
            $_.name -match "Prisma|GlobalProtect|SASE|Strata"
        }

        if ($activeSaseIncidents.Count -gt 0) {
            $firstName = $activeSaseIncidents[0].name
            if ($firstName.Length -gt 35) { $firstName = $firstName.Substring(0, 32) + "..." }
            return [PSCustomObject]@{ Status = "[ SASE / PRISMA: ALERT - $firstName ]"; Color = "Red" }
        }

        # 3. Evaluar fallas reales de componentes (Outages vs Mantenimientos)
        $outageList = $saseComponents | Where-Object { $_.status -in "major_outage", "partial_outage" }
        if ($outageList.Count -gt 0) {
            $c = $outageList[0]
            return [PSCustomObject]@{ Status = "[ SASE / PRISMA: ALERT - $($c.name) ($($c.status)) ]"; Color = "Red" }
        }

        $degradedList = $saseComponents | Where-Object { $_.status -eq "degraded_performance" }
        if ($degradedList.Count -gt 0) {
            $c = $degradedList[0]
            return [PSCustomObject]@{ Status = "[ SASE / PRISMA: DEGRADED - $($c.name) ]"; Color = "Yellow" }
        }

        $maintList = $saseComponents | Where-Object { $_.status -eq "under_maintenance" }
        if ($maintList.Count -gt 0) {
            $c = $maintList[0]
            return [PSCustomObject]@{ Status = "[ SASE / PRISMA: MAINTENANCE - $($c.name) ]"; Color = "Cyan" }
        }

        # Si el core SASE esta bien, pero Palo Alto en general tiene una degradacion menor en otro producto
        if ($data.status.indicator -ne "none") {
            return [PSCustomObject]@{ Status = "[ SASE / PRISMA: OPERATIONAL (Global Palo Alto: $($data.status.description)) ]"; Color = "Green" }
        }

        return [PSCustomObject]@{ Status = "[ SASE / PRISMA: OPERATIONAL ]"; Color = "Green" }
    } catch {
        return [PSCustomObject]@{ Status = "[ SASE / PRISMA: Status Unavailable ]"; Color = "DarkGray" }
    }
}


function Get-AzureCloudHealth {
    param(
        [string]$feedUrl = "https://azurestatuscdn.azureedge.net/en-us/status/feed/",
        [int]$timeoutMs = 3500
    )
    try {
        $xmlContent = Invoke-RestGetWithTimeout -url $feedUrl -timeoutMs $timeoutMs
        [xml]$xml = $xmlContent

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

function Test-ProbeEgressHealth {
    param(
        [int]$timeoutMs = 600
    )

    if ($global:NativeEngineAvailable) {
        try {
            $e = [FleetProbe.NativeScanner]::TestEgress("1.1.1.1", 53, $timeoutMs)
            if ($null -ne $e) {
                return [PSCustomObject]@{
                    IsHealthy  = $e.IsHealthy
                    Status     = $e.StatusText
                    StatusText = $e.StatusText
                    Target     = $e.Target
                    LatencyMs  = $e.LatencyMs
                    Color      = $e.Color
                    Message    = $e.Message
                }
            }
        } catch {}
    }

    $pinger = $null
    try {
        $pinger = New-Object System.Net.NetworkInformation.Ping

        # 1. Pila TCP/IP Local (Hardware / Loopback)
        $loopbackReply = $pinger.Send("127.0.0.1", 300)
        if ($null -eq $loopbackReply -or $loopbackReply.Status -ne [System.Net.NetworkInformation.IPStatus]::Success) {
            return [PSCustomObject]@{
                IsHealthy   = $false
                Status      = "TCP/IP STACK DOWN"
                StatusText  = "TCP/IP STACK DOWN"
                Target      = "127.0.0.1"
                LatencyMs   = 0
                Color       = "Red"
                Message     = "[ PROBE: TCP/IP Stack Failure (127.0.0.1 unreachable) ]"
            }
        }

        # 2. Canaries Globales Anycast (ICMP)
        $canaries = @("1.1.1.1", "8.8.8.8", "9.9.9.9", "208.67.222.222", "1.0.0.1")
        foreach ($target in $canaries) {
            try {
                $reply = $pinger.Send($target, $timeoutMs)
                if ($null -ne $reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $msgText = "[ PROBE: EGRESS OK ({0}: {1}ms) ]" -f $target, $reply.RoundtripTime
                    return [PSCustomObject]@{
                        IsHealthy   = $true
                        Status      = "ONLINE ({0} {1}ms)" -f $target, $reply.RoundtripTime
                        StatusText  = "ONLINE ({0} {1}ms)" -f $target, $reply.RoundtripTime
                        Target      = $target
                        LatencyMs   = [int]$reply.RoundtripTime
                        Color       = "Green"
                        Message     = $msgText
                    }
                }
            } catch {}
        }

        # 3. Fallback TCP (por si ICMP esta bloqueado por firewall)
        foreach ($target in @("1.1.1.1", "8.8.8.8")) {
            foreach ($port in @(53, 443)) {
                $tcp = $null
                try {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $async = $tcp.BeginConnect($target, $port, $null, $null)
                    $wait = $async.AsyncWaitHandle.WaitOne($timeoutMs, $false)
                    if ($wait) {
                        $tcp.EndConnect($async)
                        if ($tcp.Connected) {
                            $tcp.Close()
                            $msgText = "[ PROBE: EGRESS OK ({0} TCP:{1}) ]" -f $target, $port
                            return [PSCustomObject]@{
                                IsHealthy   = $true
                                Status      = "ONLINE ({0} TCP:{1})" -f $target, $port
                                StatusText  = "ONLINE ({0} TCP:{1})" -f $target, $port
                                Target      = "$target (TCP/$port)"
                                LatencyMs   = 0
                                Color       = "Green"
                                Message     = $msgText
                            }
                        }
                    }
                } catch {}
                finally {
                    if ($null -ne $tcp) { try { $tcp.Close() } catch {} }
                }
            }
        }

        # 4. Fallback interfaz de red
        $netAvail = $false
        try {
            $netAvail = [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
        } catch {}

        if ($netAvail) {
            return [PSCustomObject]@{
                IsHealthy   = $true
                Status      = "ONLINE (Intranet/LAN)"
                StatusText  = "ONLINE (Intranet/LAN)"
                Target      = "LAN"
                LatencyMs   = 0
                Color       = "Green"
                Message     = "[ PROBE: Local link active, canaries filtered ]"
            }
        }

        # Sin salida
        return [PSCustomObject]@{
            IsHealthy   = $false
            Status      = "NO EGRESS"
            StatusText  = "NO EGRESS"
            Target      = "ALL CANARIES"
            LatencyMs   = 0
            Color       = "Red"
            Message     = "[ PROBE: OFFLINE (No Internet / Network Egress) ]"
        }
    }
    catch {
        return [PSCustomObject]@{
            IsHealthy   = $false
            Status      = "PROBE ERROR"
            StatusText  = "PROBE ERROR"
            Target      = "Exception"
            LatencyMs   = 0
            Color       = "Red"
            Message     = "[ PROBE: Diagnostics Error: $($_.Exception.Message) ]"
        }
    }
    finally {
        if ($null -ne $pinger) { try { $pinger.Dispose() } catch {} }
    }
}

function Test-PortalHealth {
    param(
        [Parameter(Mandatory = $true)]
        [string]$name,
        [Parameter(Mandatory = $true)]
        [string]$url,
        [int]$timeoutMs = 3500,
        [int]$latencyThresholdMs = 3500
    )

    if ($global:NativeEngineAvailable) {
        $p = [FleetProbe.NativeScanner]::Ping(0, $name, $url, $timeoutMs)
        $codeDisplay = if ($p.StatusCode -gt 0) { [string]$p.StatusCode } else { "ERR" }
        $latDisplay  = if ($p.StatusCode -gt 0 -or $p.Latency -gt 0) { "$($p.Latency)ms" } else { "-" }
        return [PSCustomObject]@{
            Name        = $p.Name
            Portal      = $p.Name
            Url         = $p.Url
            Code        = $codeDisplay
            StatusCode  = $p.StatusCode
            Latency     = $p.Latency
            LatencyMs   = $p.Latency
            LatencyStr  = $latDisplay
            Status      = $p.Status
            StatusText  = $p.Status
            Color       = $p.Color
            StatusColor = $p.Color
            IsSuccess   = $p.IsSuccess
            Success     = $p.IsSuccess
            HistoryCode = $p.HistoryCode
        }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $statusCode = 0
    $statusDesc = ""
    $isSuccess = $false
    $statusText = "UNKNOWN"
    $statusColor = "Gray"
    $historyCode = "R"
    $netError = ""

    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = $timeoutMs
        $req.ReadWriteTimeout = $timeoutMs
        $req.AllowAutoRedirect = $false
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        $res = $req.GetResponse()
        $statusCode = [int]$res.StatusCode
        $statusDesc = $res.StatusDescription
        $sw.Stop()
        try { $res.Close(); $res.Dispose() } catch {}
    }
    catch [System.Net.WebException] {
        $sw.Stop()
        $ex = $_.Exception
        if ($null -ne $ex -and $null -ne $ex.Response) {
            $webRes = $ex.Response
            $statusCode = [int]$webRes.StatusCode
            $statusDesc = $webRes.StatusDescription
            try { $webRes.Close(); $webRes.Dispose() } catch {}
        }
        elseif ($null -ne $ex -and $null -ne $ex.Status) {
            $netError = $ex.Status.ToString()
        }
        else {
            $netError = "WebException"
        }
    }
    catch {
        $sw.Stop()
        $ex = $_.Exception
        $netError = if ($null -ne $ex) { $ex.GetType().Name } else { "Exception" }
    }

    $latency = $sw.ElapsedMilliseconds

    # FASE 1: CLASIFICACION DE TRANSPORTE Y CODIGOS DE ERROR HTTP
    if ($statusCode -eq 0) {
        $isSuccess = $false
        $historyCode = "R"
        if ($netError -match "NameResolutionFailure") {
            $statusText = "NO DNS/VPN"
            $statusColor = "Red"
        } elseif ($netError -match "Timeout") {
            $statusText = "TIMEOUT"
            $statusColor = "Red"
        } elseif ($netError -match "ConnectFailure") {
            $statusText = "REFUSED"
            $statusColor = "Red"
        } elseif ($netError -match "TrustFailure|SecureChannel") {
            $statusText = "SSL ERROR"
            $statusColor = "Red"
        } else {
            $statusText = "NET ERROR"
            $statusColor = "Red"
        }
    }
    elseif ($statusCode -ge 500) {
        $isSuccess = $false
        $historyCode = "R"
        $statusText = "SRV ERROR"
        $statusColor = "Red"
    }
    elseif ($statusCode -in 404, 410) {
        $isSuccess = $false
        $historyCode = "R"
        $statusText = "NOT FOUND"
        $statusColor = "Red"
    }
    elseif ($statusCode -eq 400) {
        $isSuccess = $false
        $historyCode = "Y"
        $statusText = "BAD REQ"
        $statusColor = "Yellow"
    }
    else {
        # FASE 2: RESPUESTAS FUNCIONALES
        $isSuccess = $true
        $historyCode = "G"

        if ($statusCode -eq 200) {
            $statusText = "ONLINE"
            $statusColor = "Green"
        }
        elseif ($statusCode -in 301, 302, 303, 307, 308) {
            $statusText = "AUTH/SSO"
            $statusColor = "Green"
        }
        elseif ($statusCode -in 401, 403) {
            $statusText = "AUTH REQ"
            $statusColor = "Cyan"
        }
        else {
            $statusText = "HTTP $statusCode"
            $statusColor = "Green"
        }

        if ($latency -gt $latencyThresholdMs) {
            $statusText = "DEGRADED"
            $statusColor = "Yellow"
            $historyCode = "Y"
        }
    }

    $codeDisplay = if ($statusCode -gt 0) { [string]$statusCode } else { "ERR" }
    $latDisplay  = if ($statusCode -gt 0 -or $latency -gt 0) { "${latency}ms" } else { "-" }

    return [PSCustomObject]@{
        Name        = $name
        Portal      = $name
        Url         = $url
        Code        = $codeDisplay
        StatusCode  = $statusCode
        Latency     = $latency
        LatencyMs   = $latency
        LatencyStr  = $latDisplay
        Status      = $statusText
        StatusText  = $statusText
        Color       = $statusColor
        StatusColor = $statusColor
        IsSuccess   = $isSuccess
        Success     = $isSuccess
        HistoryCode = $historyCode
    }
}

# ==============================================================================
# MOTOR MULTIHILO REACTIVO EN STREAMING (RUNSPACEPOOL DE 10 WORKERS)
# ==============================================================================
$global:NetworkWorkerScript = {
    param($name, $url, $timeoutMs)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $statusCode = 0
    $statusDesc = ""
    $isSuccess = $false
    $statusText = "UNKNOWN"
    $statusColor = "Gray"
    $historyCode = "R"
    $netError = ""

    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = $timeoutMs
        $req.ReadWriteTimeout = $timeoutMs
        $req.AllowAutoRedirect = $false
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        $res = $req.GetResponse()
        $statusCode = [int]$res.StatusCode
        $statusDesc = $res.StatusDescription
        $sw.Stop()
        try { $res.Close(); $res.Dispose() } catch {}
    }
    catch [System.Net.WebException] {
        $sw.Stop()
        $ex = $_.Exception
        if ($null -ne $ex -and $null -ne $ex.Response) {
            $webRes = $ex.Response
            $statusCode = [int]$webRes.StatusCode
            $statusDesc = $webRes.StatusDescription
            try { $webRes.Close(); $webRes.Dispose() } catch {}
        }
        elseif ($null -ne $ex -and $null -ne $ex.Status) {
            $netError = $ex.Status.ToString()
        }
        else {
            $netError = "WebException"
        }
    }
    catch {
        $sw.Stop()
        $ex = $_.Exception
        $netError = if ($null -ne $ex) { $ex.GetType().Name } else { "Exception" }
    }

    $latency = $sw.ElapsedMilliseconds

    if ($statusCode -eq 0) {
        $isSuccess = $false
        $historyCode = "R"
        if ($netError -match "NameResolutionFailure") {
            $statusText = "NO DNS/VPN"
            $statusColor = "Red"
        } elseif ($netError -match "Timeout") {
            $statusText = "TIMEOUT"
            $statusColor = "Red"
        } elseif ($netError -match "ConnectFailure") {
            $statusText = "REFUSED"
            $statusColor = "Red"
        } elseif ($netError -match "TrustFailure|SecureChannel") {
            $statusText = "SSL ERROR"
            $statusColor = "Red"
        } else {
            $statusText = "NET ERROR"
            $statusColor = "Red"
        }
    }
    elseif ($statusCode -ge 500) {
        $isSuccess = $false
        $historyCode = "R"
        $statusText = "SRV ERROR"
        $statusColor = "Red"
    }
    elseif ($statusCode -in 404, 410) {
        $isSuccess = $false
        $historyCode = "R"
        $statusText = "NOT FOUND"
        $statusColor = "Red"
    }
    elseif ($statusCode -eq 400) {
        $isSuccess = $false
        $historyCode = "Y"
        $statusText = "BAD REQ"
        $statusColor = "Yellow"
    }
    else {
        $isSuccess = $true
        $historyCode = "G"

        if ($statusCode -eq 200) {
            $statusText = "ONLINE"
            $statusColor = "Green"
        }
        elseif ($statusCode -in 301, 302, 303, 307, 308) {
            $statusText = "AUTH/SSO"
            $statusColor = "Green"
        }
        elseif ($statusCode -in 401, 403) {
            $statusText = "AUTH REQ"
            $statusColor = "Cyan"
        }
        else {
            $statusText = "HTTP $statusCode"
            $statusColor = "Green"
        }

        if ($latency -gt 3500) {
            $statusText = "DEGRADED"
            $statusColor = "Yellow"
            $historyCode = "Y"
        }
    }

    $codeDisplay = if ($statusCode -gt 0) { [string]$statusCode } else { "ERR" }
    $latDisplay  = if ($statusCode -gt 0 -or $latency -gt 0) { "${latency}ms" } else { "-" }

    return [PSCustomObject]@{
        Name        = $name
        Portal      = $name
        Url         = $url
        Code        = $codeDisplay
        StatusCode  = $statusCode
        Latency     = $latency
        LatencyMs   = $latency
        LatencyStr  = $latDisplay
        Status      = $statusText
        StatusText  = $statusText
        Color       = $statusColor
        StatusColor = $statusColor
        IsSuccess   = $isSuccess
        Success     = $isSuccess
        HistoryCode = $historyCode
    }
}

# ==============================================================================
# MOTOR C# NATIVO EMBEBIDO (COMPILED IN-MEMORY VIA ADD-TYPE)
# TaskPool asincrono, sockets persistentes y colas concurrentes de microsegundos
# ==============================================================================
$global:NativeEngineAvailable = $false

$csharpSource = @"

using System;
using System.IO;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace FleetProbe
{
    public class PortalCheckResult
    {
        public int Index;
        public string Name;
        public string Url;
        public int StatusCode;
        public string Status;
        public string Color;
        public long Latency;
        public bool IsSuccess;
        public string HistoryCode;
        public string NetError;
        public bool IsIntranet;
        public bool IsSupport;
        public string CategoryName;
        public string CategoryColor;
    }

    public class EgressCheckResult
    {
        public bool IsHealthy;
        public string Status;
        public string StatusText;
        public string Target;
        public long LatencyMs;
        public string Color;
        public string Message;
    }

    public class ConfigPortalItem
    {
        public string Name;
        public string Url;
        public bool IsSupport;
        public bool IsIntranet;
        public string CategoryName;
        public string CategoryColor;
        public int ExpectedCode;
    }

    public static class FastConfigParser
    {
        public static ConfigPortalItem[] ParseConfigFile(string filePath)
        {
            if (string.IsNullOrEmpty(filePath) || !File.Exists(filePath))
                return new ConfigPortalItem[0];

            var list = new List<ConfigPortalItem>();
            using (var reader = new StreamReader(filePath, System.Text.Encoding.UTF8))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    line = line.Trim();
                    if (line.Length == 0 || line.StartsWith("#")) continue;

                    var parts = line.Split(',');
                    if (parts.Length >= 2)
                    {
                        var item = new ConfigPortalItem();
                        item.Name = parts[0].Trim();
                        item.Url = parts[1].Trim();
                        item.ExpectedCode = 200;

                        bool isSupport = false;
                        bool isIntranet = false;

                        for (int i = 2; i < parts.Length; i++)
                        {
                            string tag = parts[i].Trim().ToUpperInvariant();
                            if (tag == "S" || tag == "SUPPORT") isSupport = true;
                            if (tag == "INT" || tag == "INTRANET") isIntranet = true;
                        }

                        string urlLower = item.Url.ToLowerInvariant();
                        if (urlLower.Contains(".corp") || urlLower.Contains(".gcp.") ||
                            urlLower.Contains("citrixstore") || urlLower.Contains("paweb"))
                        {
                            isIntranet = true;
                        }

                        item.IsSupport = isSupport;
                        item.IsIntranet = isIntranet;
                        item.CategoryName = isSupport ? "Support" : "IT Core";
                        item.CategoryColor = isSupport ? "Cyan" : "DarkYellow";

                        list.Add(item);
                    }
                }
            }
            return list.ToArray();
        }
    }

    public static class NativeScanner
    {
        [DllImport("psapi.dll")]
        public static extern int EmptyWorkingSet(IntPtr hwProc);

        public static void TrimWorkingSet()
        {
            try
            {
                GC.Collect();
                GC.WaitForPendingFinalizers();
                GC.Collect();
                EmptyWorkingSet(Process.GetCurrentProcess().Handle);
            }
            catch {}
        }

        static NativeScanner()
        {
            try
            {
                ServicePointManager.DefaultConnectionLimit = 100;
                ServicePointManager.Expect100Continue = false;
                ServicePointManager.CheckCertificateRevocationList = false;
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)3072 | (SecurityProtocolType)12288;
            }
            catch {}
        }

        public static EgressCheckResult TestEgress(string host, int port, int timeoutMs)
        {
            var sw = Stopwatch.StartNew();
            var result = new EgressCheckResult();

            // 1. Try fast ICMP ping to Anycast canaries
            string[] pingTargets = new string[] { "1.1.1.1", "8.8.8.8", "9.9.9.9", "127.0.0.1" };
            using (var pinger = new System.Net.NetworkInformation.Ping())
            {
                foreach (var tgt in pingTargets)
                {
                    try
                    {
                        var reply = pinger.Send(tgt, Math.Min(timeoutMs, 350));
                        if (reply != null && reply.Status == System.Net.NetworkInformation.IPStatus.Success)
                        {
                            sw.Stop();
                            result.IsHealthy = true;
                            result.LatencyMs = reply.RoundtripTime;
                            result.Target = tgt;
                            result.Status = "ONLINE (" + tgt + " " + result.LatencyMs + "ms)";
                            result.StatusText = result.Status;
                            result.Color = "Green";
                            result.Message = "[ PROBE: Egress OK (" + tgt + " " + result.LatencyMs + "ms) ]";
                            return result;
                        }
                    }
                    catch {}
                }
            }

            // 2. Fallback to TCP checks across DNS & HTTPS ports (port 53 and 443)
            Tuple<string, int>[] tcpTargets = new Tuple<string, int>[]
            {
                Tuple.Create(host, port),
                Tuple.Create("1.1.1.1", 53),
                Tuple.Create("8.8.8.8", 53),
                Tuple.Create("1.1.1.1", 443),
                Tuple.Create("8.8.8.8", 443),
                Tuple.Create("www.microsoft.com", 443),
                Tuple.Create("www.google.com", 443)
            };

            foreach (var tgt in tcpTargets)
            {
                try
                {
                    using (var sock = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp))
                    {
                        var ar = sock.BeginConnect(tgt.Item1, tgt.Item2, null, null);
                        if (ar.AsyncWaitHandle.WaitOne(Math.Min(timeoutMs, 400), false))
                        {
                            sock.EndConnect(ar);
                            sw.Stop();
                            result.IsHealthy = true;
                            result.LatencyMs = sw.ElapsedMilliseconds;
                            result.Target = tgt.Item1 + ":" + tgt.Item2;
                            result.Status = "ONLINE (" + tgt.Item1 + " TCP:" + tgt.Item2 + ")";
                            result.StatusText = result.Status;
                            result.Color = "Green";
                            result.Message = "[ PROBE: Egress OK (" + tgt.Item1 + " TCP:" + tgt.Item2 + " " + result.LatencyMs + "ms) ]";
                            return result;
                        }
                    }
                }
                catch {}
            }

            // 3. Fallback: Check local network interface link carrier
            bool isNetAvail = false;
            try
            {
                isNetAvail = System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable();
            }
            catch {}

            sw.Stop();
            if (isNetAvail)
            {
                result.IsHealthy = true;
                result.LatencyMs = sw.ElapsedMilliseconds;
                result.Target = "LAN/Intranet";
                result.Status = "ONLINE (Intranet/LAN)";
                result.StatusText = result.Status;
                result.Color = "Green";
                result.Message = "[ PROBE: Local link active, external canaries filtered ]";
                return result;
            }

            result.IsHealthy = false;
            result.LatencyMs = sw.ElapsedMilliseconds;
            result.Target = "ALL CANARIES";
            result.Status = "OFFLINE (No Link)";
            result.StatusText = result.Status;
            result.Color = "Red";
            result.Message = "[ PROBE: Probe offline - local network link unreachable ]";
            return result;
        }

        public static PortalCheckResult Ping(int index, string name, string url, int timeoutMs)
        {
            Stopwatch sw = Stopwatch.StartNew();
            int statusCode = 0;
            string netError = "";
            bool isSuccess = false;
            string statusText = "UNKNOWN";
            string statusColor = "Gray";
            string historyCode = "R";

            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.AllowAutoRedirect = false;
                req.KeepAlive = true;
                req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

                using (HttpWebResponse res = (HttpWebResponse)req.GetResponse())
                {
                    statusCode = (int)res.StatusCode;
                    sw.Stop();
                }
            }
            catch (WebException wex)
            {
                sw.Stop();
                if (wex.Response != null)
                {
                    using (HttpWebResponse res = (HttpWebResponse)wex.Response)
                    {
                        statusCode = (int)res.StatusCode;
                    }
                }
                else
                {
                    netError = wex.Status.ToString();
                }
            }
            catch (Exception ex)
            {
                sw.Stop();
                netError = ex.GetType().Name;
            }

            long latency = sw.ElapsedMilliseconds;

            if (statusCode == 0)
            {
                isSuccess = false;
                historyCode = "R";
                if (netError.IndexOf("NameResolutionFailure", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    statusText = "NO DNS/VPN";
                    statusColor = "Red";
                }
                else if (netError.IndexOf("Timeout", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    statusText = "TIMEOUT";
                    statusColor = "Red";
                }
                else if (netError.IndexOf("ConnectFailure", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    statusText = "REFUSED";
                    statusColor = "Red";
                }
                else if (netError.IndexOf("TrustFailure", StringComparison.OrdinalIgnoreCase) >= 0 || netError.IndexOf("SecureChannel", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    statusText = "SSL ERROR";
                    statusColor = "Red";
                }
                else
                {
                    statusText = "NET ERROR";
                    statusColor = "Red";
                }
            }
            else if (statusCode >= 500)
            {
                isSuccess = false;
                historyCode = "R";
                statusText = "SRV ERROR";
                statusColor = "Red";
            }
            else if (statusCode == 404 || statusCode == 410)
            {
                isSuccess = false;
                historyCode = "R";
                statusText = "NOT FOUND";
                statusColor = "Red";
            }
            else if (statusCode == 400)
            {
                isSuccess = false;
                historyCode = "Y";
                statusText = "BAD REQ";
                statusColor = "Yellow";
            }
            else
            {
                isSuccess = true;
                historyCode = "G";

                if (statusCode == 200)
                {
                    statusText = "ONLINE";
                    statusColor = "Green";
                }
                else if (statusCode == 301 || statusCode == 302 || statusCode == 303 || statusCode == 307 || statusCode == 308)
                {
                    statusText = "AUTH/SSO";
                    statusColor = "Green";
                }
                else if (statusCode == 401 || statusCode == 403)
                {
                    statusText = "AUTH REQ";
                    statusColor = "Cyan";
                }
                else
                {
                    statusText = "HTTP " + statusCode;
                    statusColor = "Green";
                }

                if (latency > 3500)
                {
                    statusText = "DEGRADED";
                    statusColor = "Yellow";
                    historyCode = "Y";
                }
            }

            PortalCheckResult r = new PortalCheckResult();
            r.Index = index;
            r.Name = name;
            r.Url = url;
            r.StatusCode = statusCode;
            r.Status = statusText;
            r.Color = statusColor;
            r.Latency = latency;
            r.IsSuccess = isSuccess;
            r.HistoryCode = historyCode;
            r.NetError = netError;
            return r;
        }
    }

    public class ScanSession
    {
        private ConcurrentQueue<PortalCheckResult> _queue = new ConcurrentQueue<PortalCheckResult>();
        private int _total;
        private int _completedCount;
        private Task _allTasks;

        public bool IsFinished { get { return _allTasks != null && _allTasks.IsCompleted && _queue.IsEmpty; } }
        public int CompletedCount { get { return _completedCount; } }
        public int TotalCount { get { return _total; } }

        public static ScanSession Start(string[] names, string[] urls, int timeoutMs)
        {
            ScanSession session = new ScanSession();
            session._total = names.Length;
            session._completedCount = 0;

            Task[] tasks = new Task[names.Length];
            for (int i = 0; i < names.Length; i++)
            {
                int idx = i;
                string nm = names[i];
                string u = urls[i];
                tasks[i] = Task.Factory.StartNew(() =>
                {
                    PortalCheckResult res = NativeScanner.Ping(idx, nm, u, timeoutMs);
                    session._queue.Enqueue(res);
                    System.Threading.Interlocked.Increment(ref session._completedCount);
                });
            }

            session._allTasks = Task.WhenAll(tasks);
            return session;
        }

        public PortalCheckResult TryGetNext()
        {
            PortalCheckResult res;
            if (_queue.TryDequeue(out res))
            {
                return res;
            }
            return null;
        }
    }

    public class PortalTelemetryState
    {
        public string Url;
        public string Name;
        public string Category;
        public bool IsIntranet;
        public int HistSuccess;
        public int HistFailure;
        public int SessionSuccess;
        public int SessionFailure;
        public int ConsecutiveFailures;
        public bool IsHardOutage;
        public DateTime SoftOutageStartTime;
        public DateTime HardOutageStartTime;
        public long TotalDowntimeSeconds;
        public int IncidentCount;
        private char[] _timeline = new char[10] { 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O', 'O' };

        public void AddTimelineSample(char code)
        {
            for (int i = 0; i < 9; i++)
            {
                _timeline[i] = _timeline[i + 1];
            }
            _timeline[9] = code;
        }

        public string GetTimeline()
        {
            return new string(_timeline);
        }

        public double GetHistUptime()
        {
            int tot = HistSuccess + HistFailure;
            if (tot <= 0) return 100.0;
            return ((double)HistSuccess / tot) * 100.0;
        }

        public double GetSessionUptime()
        {
            int tot = SessionSuccess + SessionFailure;
            if (tot <= 0) return 100.0;
            return ((double)SessionSuccess / tot) * 100.0;
        }
    }

    public class SegmentedBlastRadiusResult
    {
        public bool GlobalDisrupted;
        public bool IntranetDisrupted;
        public int IntranetFailures;
        public int IntranetTotal;
        public int PublicFailures;
        public int PublicTotal;
        public bool IsDisrupted;
    }

    public class FleetKpisResult
    {
        public double HistSla;
        public double SessSla;
        public string FleetMttr;
        public int Incidents;
        public int HardOutagesCount;
        public int SoftFailsCount;
        public string OutageDisplay;
        public string OutageColor;
        public int TotalOnline;
        public int TotalDegraded;
        public int TotalOutage;
        public int TotalPortals;
    }

    public class FleetTelemetryEngine
    {
        private static readonly FleetTelemetryEngine _instance = new FleetTelemetryEngine();
        public static FleetTelemetryEngine Instance { get { return _instance; } }

        private readonly ConcurrentDictionary<string, PortalTelemetryState> _portals =
            new ConcurrentDictionary<string, PortalTelemetryState>(StringComparer.OrdinalIgnoreCase);

        public int ResolvedIncidents = 0;
        public long TotalFleetDowntimeSeconds = 0;

        public ConcurrentDictionary<string, PortalTelemetryState> Portals { get { return _portals; } }

        public void InitializeFromCsv(string csvPath)
        {
            if (string.IsNullOrEmpty(csvPath) || !File.Exists(csvPath)) return;
            try
            {
                using (var reader = new StreamReader(csvPath, System.Text.Encoding.UTF8))
                {
                    string header = reader.ReadLine();
                    if (header == null) return;
                    var cols = header.Split(',');
                    int urlIdx = -1, sIdx = -1, fIdx = -1, nameIdx = -1, catIdx = -1;
                    for (int i = 0; i < cols.Length; i++)
                    {
                        string c = cols[i].Trim().ToLowerInvariant();
                        if (c == "url") urlIdx = i;
                        else if (c == "success") sIdx = i;
                        else if (c == "failure") fIdx = i;
                        else if (c == "portal" || c == "name") nameIdx = i;
                        else if (c == "category") catIdx = i;
                    }
                    if (urlIdx < 0) return;

                    string line;
                    while ((line = reader.ReadLine()) != null)
                    {
                        if (string.IsNullOrWhiteSpace(line)) continue;
                        var parts = line.Split(',');
                        if (parts.Length > urlIdx)
                        {
                            string u = parts[urlIdx].Trim();
                            if (string.IsNullOrEmpty(u)) continue;

                            int s = 0, f = 0;
                            if (sIdx >= 0 && parts.Length > sIdx) int.TryParse(parts[sIdx].Trim(), out s);
                            if (fIdx >= 0 && parts.Length > fIdx) int.TryParse(parts[fIdx].Trim(), out f);

                            var p = _portals.GetOrAdd(u, key => new PortalTelemetryState { Url = key });
                            p.HistSuccess = s;
                            p.HistFailure = f;
                            if (nameIdx >= 0 && parts.Length > nameIdx && string.IsNullOrEmpty(p.Name))
                                p.Name = parts[nameIdx].Trim();
                            if (catIdx >= 0 && parts.Length > catIdx && string.IsNullOrEmpty(p.Category))
                                p.Category = parts[catIdx].Trim();
                        }
                    }
                }
            }
            catch {}
        }

        public PortalTelemetryState RecordResult(string url, string name, string category, bool isIntranet, bool isSuccess, int statusCode, long latencyMs, bool suppressFailure)
        {
            var p = _portals.GetOrAdd(url, key => new PortalTelemetryState
            {
                Url = key,
                Name = name,
                Category = category,
                IsIntranet = isIntranet
            });

            p.Name = name;
            p.Category = category;
            p.IsIntranet = isIntranet;

            if (isSuccess)
            {
                p.HistSuccess++;
                p.SessionSuccess++;
                p.AddTimelineSample(statusCode == 200 && latencyMs <= 3500 ? 'O' : 'D');

                if (p.ConsecutiveFailures > 0)
                {
                    if (p.IsHardOutage)
                    {
                        long downSec = (long)(DateTime.UtcNow - p.HardOutageStartTime).TotalSeconds;
                        if (downSec < 1) downSec = 1;
                        p.TotalDowntimeSeconds += downSec;
                        TotalFleetDowntimeSeconds += downSec;
                        ResolvedIncidents++;
                    }
                    p.ConsecutiveFailures = 0;
                    p.IsHardOutage = false;
                }
            }
            else
            {
                p.HistFailure++;
                p.SessionFailure++;

                if (!suppressFailure)
                {
                    p.ConsecutiveFailures++;
                    if (p.ConsecutiveFailures == 1)
                    {
                        p.AddTimelineSample('D');
                        p.SoftOutageStartTime = DateTime.UtcNow;
                    }
                    else if (p.ConsecutiveFailures >= 3)
                    {
                        p.AddTimelineSample('X');
                        if (!p.IsHardOutage)
                        {
                            p.IsHardOutage = true;
                            p.IncidentCount++;
                            p.HardOutageStartTime = DateTime.UtcNow;
                        }
                    }
                    else
                    {
                        p.AddTimelineSample('D');
                    }
                }
                else
                {
                    p.AddTimelineSample('D');
                }
            }

            return p;
        }

        public static SegmentedBlastRadiusResult EvaluateSegmented(
            bool[] isIntranet,
            bool[] isSuccess,
            double globalThreshold,
            double intranetThreshold)
        {
            var res = new SegmentedBlastRadiusResult();
            int pubTotal = 0, pubFail = 0;
            int intTotal = 0, intFail = 0;

            for (int i = 0; i < isIntranet.Length; i++)
            {
                bool fail = !isSuccess[i];
                if (isIntranet[i])
                {
                    intTotal++;
                    if (fail) intFail++;
                }
                else
                {
                    pubTotal++;
                    if (fail) pubFail++;
                }
            }

            res.IntranetTotal = intTotal;
            res.IntranetFailures = intFail;
            res.PublicTotal = pubTotal;
            res.PublicFailures = pubFail;
            res.IntranetDisrupted = (intTotal >= 2 && ((double)intFail / intTotal) >= intranetThreshold);
            res.GlobalDisrupted = (pubTotal >= 3 && ((double)pubFail / pubTotal) >= globalThreshold);
            res.IsDisrupted = (res.GlobalDisrupted || res.IntranetDisrupted);
            return res;
        }

        public FleetKpisResult ComputeKpis()
        {
            var kpis = new FleetKpisResult();
            long totalHistS = 0, totalHistF = 0;
            long totalSessS = 0, totalSessF = 0;
            int hardOutages = 0;
            int softFails = 0;
            int onlineCount = 0, degCount = 0, outCount = 0;

            foreach (var kvp in _portals)
            {
                var p = kvp.Value;
                totalHistS += p.HistSuccess;
                totalHistF += p.HistFailure;
                totalSessS += p.SessionSuccess;
                totalSessF += p.SessionFailure;

                if (p.IsHardOutage) hardOutages++;
                else if (p.ConsecutiveFailures == 1) softFails++;

                string tl = p.GetTimeline();
                if (!string.IsNullOrEmpty(tl))
                {
                    char last = tl[tl.Length - 1];
                    if (last == 'O') onlineCount++;
                    else if (last == 'D') degCount++;
                    else if (last == 'X') outCount++;
                }
            }

            long totHist = totalHistS + totalHistF;
            kpis.HistSla = totHist > 0 ? ((double)totalHistS / totHist) * 100.0 : 100.0;

            long totSess = totalSessS + totalSessF;
            kpis.SessSla = totSess > 0 ? ((double)totalSessS / totSess) * 100.0 : 100.0;

            kpis.Incidents = ResolvedIncidents;

            if (ResolvedIncidents > 0)
            {
                long avgSec = TotalFleetDowntimeSeconds / ResolvedIncidents;
                long m = avgSec / 60;
                long s = avgSec % 60;
                kpis.FleetMttr = string.Format("{0}m {1:D2}s", m, s);
            }
            else
            {
                kpis.FleetMttr = "0m 00s";
            }

            kpis.HardOutagesCount = hardOutages;
            kpis.SoftFailsCount = softFails;

            string outDisp = hardOutages.ToString();
            if (softFails > 0) outDisp += " (" + softFails + " Soft)";
            kpis.OutageDisplay = outDisp;

            if (hardOutages > 0) kpis.OutageColor = "Red";
            else if (softFails > 0) kpis.OutageColor = "Yellow";
            else kpis.OutageColor = "Green";

            kpis.TotalOnline = onlineCount;
            kpis.TotalDegraded = degCount;
            kpis.TotalOutage = outCount;
            kpis.TotalPortals = _portals.Count;

            return kpis;
        }

        public void SaveSnapshotCsv(string csvPath)
        {
            if (string.IsNullOrEmpty(csvPath)) return;
            try
            {
                string dir = Path.GetDirectoryName(csvPath);
                if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                    Directory.CreateDirectory(dir);

                using (var writer = new StreamWriter(csvPath, false, System.Text.Encoding.UTF8))
                {
                    writer.WriteLine("Portal,Url,Category,Success,Failure,UptimePercent,LastCheck");
                    string now = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss");
                    foreach (var kvp in _portals)
                    {
                        var p = kvp.Value;
                        double up = p.GetHistUptime();
                        char q = (char)34;
                        string nm = p.Name != null ? p.Name.Replace(q, (char)39) : "";
                        string u = p.Url != null ? p.Url.Replace(q, (char)39) : "";
                        string cat = p.Category != null ? p.Category.Replace(q, (char)39) : "IT Core";
                        writer.WriteLine(q + nm + q + "," + q + u + q + "," + q + cat + q + "," + p.HistSuccess + "," + p.HistFailure + "," + up.ToString("F2") + "," + q + now + q);
                    }
                }
            }
            catch {}
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct COORD
    {
        public short X;
        public short Y;
        public COORD(short x, short y) { X = x; Y = y; }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SMALL_RECT
    {
        public short Left;
        public short Top;
        public short Right;
        public short Bottom;
        public SMALL_RECT(short l, short t, short r, short b)
        {
            Left = l; Top = t; Right = r; Bottom = b;
        }
    }

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    public struct CHAR_INFO
    {
        [FieldOffset(0)] public char UnicodeChar;
        [FieldOffset(2)] public ushort Attributes;
    }

    public class FastCanvas
    {
        private const int STD_OUTPUT_HANDLE = -11;

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool WriteConsoleOutputW(
            IntPtr hConsoleOutput,
            CHAR_INFO[] lpBuffer,
            COORD dwBufferSize,
            COORD dwBufferCoord,
            ref SMALL_RECT lpWriteRegion
        );

        private IntPtr _hConsole;
        private int _width;
        private int _height;
        private CHAR_INFO[] _buffer;

        private static FastCanvas _instance;
        public static FastCanvas Instance
        {
            get
            {
                if (_instance == null)
                {
                    _instance = new FastCanvas(128, 50);
                }
                return _instance;
            }
        }

        public FastCanvas(int width, int height)
        {
            _width = width;
            _height = height;
            _buffer = new CHAR_INFO[width * height];
            _hConsole = GetStdHandle(STD_OUTPUT_HANDLE);
            Clear();
        }

        public void Clear()
        {
            for (int i = 0; i < _buffer.Length; i++)
            {
                _buffer[i].UnicodeChar = ' ';
                _buffer[i].Attributes = 0x0007;
            }
        }

        public void ClearRow(int y)
        {
            if (y < 0 || y >= _height) return;
            int start = y * _width;
            for (int i = 0; i < _width; i++)
            {
                _buffer[start + i].UnicodeChar = ' ';
                _buffer[start + i].Attributes = 0x0007;
            }
        }

        public static ushort ColorNameToAttr(string color)
        {
            if (string.IsNullOrEmpty(color)) return 0x0007;
            switch (color.ToLowerInvariant())
            {
                case "black":       return 0x0000;
                case "darkblue":    return 0x0001;
                case "darkgreen":   return 0x0002;
                case "darkcyan":    return 0x0003;
                case "darkred":     return 0x0004;
                case "darkmagenta": return 0x0005;
                case "darkyellow":  return 0x0006;
                case "gray":        return 0x0007;
                case "darkgray":    return 0x0008;
                case "blue":        return 0x0009;
                case "green":       return 0x000A;
                case "cyan":        return 0x000B;
                case "red":         return 0x000C;
                case "magenta":     return 0x000D;
                case "yellow":      return 0x000E;
                case "white":       return 0x000F;
                default:            return 0x0007;
            }
        }

        public void WriteSpan(int x, int y, string text, string color = "Gray", string bg = "Black")
        {
            if (y < 0 || y >= _height || string.IsNullOrEmpty(text)) return;
            ushort attr = (ushort)(ColorNameToAttr(color) | (ColorNameToAttr(bg) << 4));
            for (int i = 0; i < text.Length; i++)
            {
                int posX = x + i;
                if (posX >= 0 && posX < _width)
                {
                    int idx = y * _width + posX;
                    _buffer[idx].UnicodeChar = text[i];
                    _buffer[idx].Attributes = attr;
                }
            }
        }

        public bool FlushRow(int y)
        {
            if (y < 0 || y >= _height) return false;
            try
            {
                int bufW = Console.BufferWidth;
                int w = Math.Min(_width, bufW);
                if (w <= 0) return false;

                COORD bufSize = new COORD((short)_width, (short)_height);
                COORD bufCoord = new COORD(0, (short)y);
                SMALL_RECT region = new SMALL_RECT(0, (short)y, (short)(w - 1), (short)y);
                return WriteConsoleOutputW(_hConsole, _buffer, bufSize, bufCoord, ref region);
            }
            catch
            {
                return false;
            }
        }

        public bool FlushRegion(int top, int bottom)
        {
            if (top < 0) top = 0;
            if (bottom >= _height) bottom = _height - 1;
            if (top > bottom) return false;

            try
            {
                int bufW = Console.BufferWidth;
                int w = Math.Min(_width, bufW);
                if (w <= 0) return false;

                COORD bufSize = new COORD((short)_width, (short)_height);
                COORD bufCoord = new COORD(0, (short)top);
                SMALL_RECT region = new SMALL_RECT(0, (short)top, (short)(w - 1), (short)bottom);
                return WriteConsoleOutputW(_hConsole, _buffer, bufSize, bufCoord, ref region);
            }
            catch
            {
                return false;
            }
        }

        public bool FlushAll()
        {
            return FlushRegion(0, _height - 1);
        }
    }
}

"@

try {
    Add-Type -TypeDefinition $csharpSource -Language CSharp -ErrorAction Stop
    $global:NativeEngineAvailable = $true
    try { [FleetProbe.NativeScanner]::TrimWorkingSet() } catch {}
} catch {
    if ([FleetProbe.NativeScanner] -as [type]) {
        $global:NativeEngineAvailable = $true
        try { [FleetProbe.NativeScanner]::TrimWorkingSet() } catch {}
    } else {
        $global:NativeEngineAvailable = $false
        $global:AddTypeError = $_.Exception.Message
    }
}
function Invoke-FleetHealthScanStreaming {
    param(
        [Parameter(Mandatory = $true)]
        [array]$portals,
        [int]$timeoutMs = 3500,
        [int]$maxThreads = 10,
        [scriptblock]$OnPortalComplete
    )

    if ($portals.Count -eq 0) { return @() }

    # RUTA OPTIMIZADA A: MOTOR C# NATIVO EMBEBIDO (ZERO RUNSPACE OVERHEAD)
    if ($global:NativeEngineAvailable) {
        $names = [string[]]($portals | ForEach-Object { $_.Name })
        $urls  = [string[]]($portals | ForEach-Object { $_.Url })
        $results = New-Object object[] $portals.Count

        $session = [FleetProbe.ScanSession]::Start($names, $urls, $timeoutMs)

        while (-not $session.IsFinished) {
            $item = $session.TryGetNext()
            while ($null -ne $item) {
                $codeDisplay = if ($item.StatusCode -gt 0) { [string]$item.StatusCode } else { "ERR" }
                $latDisplay  = if ($item.StatusCode -gt 0 -or $item.Latency -gt 0) { "$($item.Latency)ms" } else { "-" }

                $psRes = [PSCustomObject]@{
                    Name        = $item.Name
                    Portal      = $item.Name
                    Url         = $item.Url
                    Code        = $codeDisplay
                    StatusCode  = $item.StatusCode
                    Latency     = $item.Latency
                    LatencyMs   = $item.Latency
                    LatencyStr  = $latDisplay
                    Status      = $item.Status
                    StatusText  = $item.Status
                    Color       = $item.Color
                    StatusColor = $item.Color
                    IsSuccess   = $item.IsSuccess
                    Success     = $item.IsSuccess
                    HistoryCode = $item.HistoryCode
                }

                $results[$item.Index] = $psRes

                if ($OnPortalComplete) {
                    try { & $OnPortalComplete $item.Index $psRes } catch {}
                }

                $item = $session.TryGetNext()
            }
            [System.Threading.Thread]::Sleep(10)
        }

        return $results
    }

    # RUTA B (FALLBACK): MOTOR RUNSPACEPOOL MULTIHILO DE POWERSHELL
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $maxThreads)
    $pool.Open()

    $jobs = New-Object System.Collections.Generic.List[PSCustomObject]
    $results = New-Object object[] $portals.Count

    try {
        for ($i = 0; $i -lt $portals.Count; $i++) {
            $p = $portals[$i]
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript($global:NetworkWorkerScript).AddArgument($p.Name).AddArgument($p.Url).AddArgument($timeoutMs)
            $handle = $ps.BeginInvoke()

            $jobs.Add([PSCustomObject]@{
                PowerShell = $ps
                Handle     = $handle
                Index      = $i
                Portal     = $p
            })
        }

        $completed = 0
        while ($completed -lt $jobs.Count) {
            foreach ($job in $jobs) {
                if ($null -ne $job.Handle -and $job.Handle.IsCompleted) {
                    $res = $job.PowerShell.EndInvoke($job.Handle)
                    $job.PowerShell.Dispose()
                    $job.Handle = $null
                    $completed++

                    $finalRes = $res[0]
                    $results[$job.Index] = $finalRes

                    if ($OnPortalComplete) {
                        try {
                            & $OnPortalComplete $job.Index $finalRes
                        } catch {}
                    }
                }
            }
            [System.Threading.Thread]::Sleep(15)
        }
    }
    finally {
        try { $pool.Close(); $pool.Dispose() } catch {}
    }

    return $results
}
