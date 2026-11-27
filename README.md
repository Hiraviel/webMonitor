# Preventive Portal Monitor — IT & Support (NOC Edition)

A proactive, lightweight, and resilient monitoring engine built for NOC and SRE teams to track portal availability, latency degradation, and infrastructure health in real time without external agent dependencies.

## Overview

The Preventive Portal Monitor runs continuously on operations consoles, jump hosts, or administrative workstations. It performs deterministic health checks on enterprise web applications, integrates external cloud telemetry (Azure Infrastructure and Palo Alto SASE / Prisma Access), and tracks operational SLAs, Outage incidents, and MTTR (Mean Time to Recovery) across shifts.

It incorporates a 3-Layer Probe Resiliency Architecture designed to prevent false alarms, protect SLA integrity during local VPN or network disconnections, and eliminate flapping alerts through multi-cycle state confirmation.

## What's New in v4.5 (NOC TUI & Resiliency Edition)

### 1. High-Performance Multithreading (`src/Network.ps1`)
* **Sub-Second Fleet Polling:** Upgraded from sequential HTTP requests (15-20s cycle lag) to an asynchronous `RunspacePool` architecture with 10 worker threads. Entire fleet scan now completes in `<1s` (`0s (Multithread)`).
* **Deterministic Timeout Safety:** Each worker enforces strict 3.5s socket limits and safe exception unwrap to prevent thread starvation.

### 2. Zero-Flicker In-Place Live Refresh (`src/Views.ps1`)
* **100% Live Buffer Repositioning:** Eliminated full-screen `Clear-Host` wipes between cycles. The dashboard repositions the console cursor via `[Console]::SetCursorPosition(0, 0)` and hides the cursor during render for instant, flicker-free updates.
* **Live Second-by-Second Countdown:** The footer updates remaining cadence time continuously in place (`\r [>>] Next scan in: 01m 45s`) without repainting the table or header.
* **Pure 7-Bit ASCII Source Code:** All Box-Drawing glyphs and UI icons are generated at runtime via `[char]0xXXXX` hexadecimal literals, ensuring 100% immunity to Windows PowerShell 5.1 ANSI/UTF-8 encoding mismatches.

### 3. Segmented Circuit Breaker & Multi-Tag Inventory (`monitor.ps1`, `src/Telemetry.ps1`)
* **Multi-Tag Flexibility (`portales.txt`):** Supports combined category and routing tags in any order (e.g., `S` for Support, `INT` for Intranet/VPN-dependent).
* **Dual-Segment Network Isolation:**
  * **Public Cloud SaaS:** Uninterrupted 24/7 monitoring. If local VPN disconnects, cloud portals (ServiceNow, CloudPC, Workday, M365) continue active polling and real-time incident alerting.
  * **Internal Intranet (`INT`):** If a VPN drop or gateway flap is detected (>=50% internal transport failure), intranet portals are isolated as `[- FROZEN]` in gray. Their SLA and incident counters are frozen without penalizing shift metrics.
* **Auto-Detection Safety Net:** Targets with internal naming patterns (`.corp`, `.gcp.`, `citrixstore`, `paweb`) are automatically recognized as intranet even if the `INT` tag is omitted.

### 4. Visual Observability Upgrades
* **SRE Metric Cards:** Header grid featuring `HIST SLA`, `SESSION SLA`, `FLEET MTTR`, `INCIDENTS`, and `ACTIVE OUTAGES`.
* **Fleet Health Gauge Bar:** Proportional real-time health bar (`[████████████████████] Online / Soft / Outage`).
* **Visual Categorization:** Visual glyph tagging separating `◈ IT Core` (DarkYellow) from `◇ Support` (Cyan).
* **High-Density Sparklines:** 10-sample rolling timeline utilizing Unicode block glyphs.

## Key Features

* Deterministic Start-to-Start Cadence: Measures execution duration in real time and offsets countdown delays so that scanning cycles initiate exactly on target (default: 120s) without temporal drift.
* 3-Layer Probe Resiliency Engine: Multi-stage defense ensuring that local workstation network events, VPN drops, and momentary socket glitches never generate false incident tickets or degrade SLA calculations.
* Granular HTTP & Transport Diagnostics: Disentangles transport/network failures (DNS, timeout, SSL, refused connections, 5xx, 404) from functional responses. High latency (> 3,500 ms) marks functional portals as DEGRADED rather than offline.
* Strict HTTP Timeout Guardrails: Enforces a strict 3,500 ms timeout per endpoint and cloud status feed, preventing socket stalls and thread starvation even during mass network dropouts.
* Formal SRE Incident Lifecycle & MTTR: Tracks transitions through Soft and Hard failure states. Promotes incidents only upon verified consecutive failures, calculating true MTTR (Total Downtime / Resolved Incidents) upon recovery.
* Dual SLA Visibility: Tracks persistent Historical SLA (restored across reboots from the local CSV database) alongside Session SLA (shift stability).
* Dual-Engine KeepAlive: Native Win32 `kernel32.dll` thread execution state management with a fallback virtual key engine (`WScript.Shell` F15) to maintain console visibility during operations shifts, cleaning up gracefully on exit.
* Calibrated 128-Column Console UI: High-contrast, single-screen dashboard with color-coded categories (IT Core in Orange/DarkYellow, Support in Cyan) and historical 10-sample sparkline timelines.
* In-Console Operations Hotkeys: Immediate access to on-the-fly interval configuration, target list editing, forced scans, and full-screen diagnostic modals.

## Project Structure

The project follows a decoupled modular architecture rooted in a single directory:

```text
MonitorPortales/
├── monitor.ps1          # Main orchestrator (scheduling loop, scan dispatch, hotkey handler)
├── portales.txt         # Configuration file listing target portals and category tags
├── history.csv          # Telemetry database snapshot (auto-generated every 5 minutes)
├── outages.log          # Audit trail logging detected outages and resolved downtime
├── README.md            # Technical and operational documentation
└── src/
    ├── KeepAlive.ps1    # Power management and anti-sleep engine (Win32 API + COM fallback)
    ├── Network.ps1      # WebRequest engine, timeout enforcement, egress check, cloud feeds
    ├── Telemetry.ps1    # State machine, blast radius consensus, soft/hard filter, SLA & MTTR
    └── Views.ps1        # Console renderers, table formatting, and full-screen dashboards
```

## 3-Layer Probe Resiliency Architecture

In standard operations, a probe running on an administrative workstation or jump host is exposed to local disruptions (VPN disconnections, WiFi roaming, screen lock sleep states, or transient packet loss). Without resiliency controls, these events trigger dozens of false outages and destroy SLA credibility. This engine deploys three sequential defense layers:

### Layer 1: Probe Egress Pre-flight Check

Before initiating any portal scans, `Network.ps1` runs `Test-LocalProbeEgress` to verify local network interface sanity:

* Step 1: Tests local loopback adapter (`127.0.0.1:53` or TCP stack) to confirm local TCP/IP stack health.
* Step 2: Probes Anycast DNS root (`1.1.1.1:53` TCP) with a strict 2,000 ms timeout to ensure active default gateway egress.
* Outcome: If egress fails, the monitor flags `[ PROBE: NO EGRESS (NIC/WiFi DOWN) ]`, alerts the operator immediately, and pauses scanning to avoid logging false downtime for every portal.

### Layer 2: Blast Radius & Fleet Consensus Circuit Breaker

When an operator disconnects from the enterprise VPN or corporate split-tunneling drops, all internal portals immediately fail network transport (`REFUSED`, `TIMEOUT`, `NO DNS/VPN`). 

* Consensus Threshold: `Telemetry.ps1` evaluates `Test-FleetBlastRadius`. If 60% or more of the monitored fleet experiences transport/network errors simultaneously in a single cycle, the engine mathematically classifies the event as a Vantage Point Route Failure rather than individual application outages.
* Metric Protection: When triggered, the circuit breaker displays an advisory warning banner:
  `[!] BLAST RADIUS WARNING: 22 of 23 portals (96%) failed network transport simultaneously.`
  `[!] Probe Route/VPN Disruption detected. SLA & Outages FROZEN for this cycle to prevent false incidents.`
* SLA Preservation: Session and Historical SLA counters are frozen for that cycle, zero entries are written to `outages.log`, and sparklines record a neutral `-` mark instead of a failure `X`.

### Layer 3: Soft vs Hard Outage Confirmation (Anti-Flapping)

To prevent transient hiccups (single TCP resets, SSL renegotiation timeouts, or probe packet drops) from opening noisy incident tickets, `Telemetry.ps1` implements a multi-cycle state machine:

* Soft Fail (Cycle 1): The first time an individual portal fails, it enters a Soft Fail state. The row renders in Yellow as a visual operational warning. No entry is written to `outages.log`, and the incident counter is not incremented.
* Hard Outage (Cycle 2+ Consecutively): If the portal remains down for 2 consecutive cycles (4 minutes under standard 120s cadence), it is formally promoted to a Hard Outage. The row renders in Red, `Active Outages` increments in the executive banner, and an official audit entry is logged to `outages.log`.
* Auto-Heal: If a portal recovers on cycle 2 while still in Soft state, the counter quietly resets to zero. False alerts are eliminated completely.
* Downtime & MTTR: When a Hard Outage recovers, the engine calculates the exact duration from the original cycle 1 failure timestamp, logs the resolution to `outages.log`, and recalculates Fleet MTTR.

## Configuration: `portales.txt`

The target portal list is defined in `portales.txt`, located in the root script directory.

### Syntax

```text
Name, URL[, Tag1, Tag2, ...]
```

* **Name**: Display name of the service or portal. Names longer than 21 characters are trimmed with an ellipsis in the console table.
* **URL**: Full HTTP or HTTPS endpoint.
* **Tag `S` (Optional)**: Designates the portal as a **Support** application (rendered in Cyan with `◇`). If omitted, the portal defaults to **IT Core** (rendered in DarkYellow with `◈`).
* **Tag `INT` (Optional)**: Designates the portal as **Intranet / VPN-dependent** (e.g. `.corp`, on-premises, or private cloud interconnects). If the local VPN drops, only `INT` portals are isolated as `[- FROZEN]` without penalizing SLA, while public cloud monitoring continues at 100% capacity.
* Comment lines starting with `#` and empty lines are ignored.

### Example `portales.txt`

```text
# ==============================================================================
# PORTAL MONITOR INVENTORY
# Syntax: Portal Name, URL [, Tag1, Tag2, ...]
# ==============================================================================
# Public Cloud SaaS (24/7 Monitoring independent of VPN)
ServiceNow, https://portal.service-now.com, S
CloudPC, https://windows.cloud.microsoft, S
Bifrost, https://apps.powerapps.com/, S
Outlook Web, https://outlook.office.com

# Internal Intranet (VPN / Intranet Dependent)
DRA S1, https://den3w1nqdaa01.corp, S, INT
Citrix Store, https://citrixstore.internal.corp, INT
CWOW Launcher, https://r20.cwow.gcp..., INT
```

## Console Interface & Metrics

### Executive Header

The top banner provides immediate situational awareness:

* Last Check & Cadence: Timestamp of last execution, configured cycle time, and exact Scan Duration in seconds.
* MS Infrastructure: Operational status parsed from the official Azure Status RSS feed.
* Palo Alto / SASE: Real-time status parsed from Palo Alto Networks API (monitoring Prisma Access, GlobalProtect, and Strata).
* Local Probe Link: Real-time Layer 1 probe egress health (`[ PROBE: EGRESS OK ]` or failure indicator).
* Portales & Telemetry DB: Active category legends (IT Core in Orange, Support in Cyan) and last CSV snapshot timestamp.
* Fleet NOC SLA: Executive metrics showing Fleet Historical SLA %, Shift Session SLA %, Total Resolved Incidents, Fleet MTTR, and Active Outages count (with Soft Fail count indicator).
* KeepAlive: Operational state of the anti-sleep engine.
* Hotkeys Bar: Quick guide to interactive keyboard commands.

### Grid Columns (128 Characters Width)

* STATUS (14 chars): Diagnostic badge (`[ ONLINE ]`, `[ AUTH/SSO ]`, `[ AUTH REQ ]`, `[ DEGRADED ]`, `[ REFUSED ]`, `[ TIMEOUT ]`, `[ NO DNS/VPN ]`, `[ SSL ERROR ]`, `[ NOT FOUND ]`).
* PORTAL (22 chars): Portal display name colored by category (Orange for IT Core, Cyan for Support).
* CODE (8 chars): HTTP response status code (`200`, `302`, `401`, `503`, or `ERR`).
* LATENCY (10 chars): Round-trip response time in milliseconds. Colored DarkGreen (<800ms), Yellow (800-3500ms), or Red (>3500ms).
* TIMELINE(10) (14 chars): Sparkline showing the last 10 verification cycles (`O` in Green for online, `D` in Yellow for degraded, `X` in Red for failure, `-` in DarkGray for suppressed).
* VERIF(OK|NO) (15 chars): Total successful vs failed check counts since inception or reset.
* UPTIME % (9 chars): Historical availability percentage, colored Green (>=99%), Yellow (>=95%), or Red (<95%).
* URL (36 chars): Target address, trimmed to fit within the 128-column boundary without line wrapping.

## Interactive Hotkeys

During the countdown interval, the operator can interact with the monitor using single keystrokes without stopping execution:

* `[1] Interval`: Prompts to update the scan cycle duration (minimum: 5 seconds) and triggers an immediate scan.
* `[2] Edit List`: Opens `portales.txt` in Notepad. After saving changes, press `[3]` to reload.
* `[3] Scan Now`: Bypasses the countdown timer and forces an immediate health scan and config reload.
* `[4] Outages Log`: Opens the in-console Outages modal displaying recent audit trail records.
* `[5] CSV DB`: Opens the in-console CSV database viewer showing recent telemetry snapshots.
* `[6] SASE Details`: Opens full-screen dashboard querying live Palo Alto Networks components and active incidents.
* `[7] NOC Metrics`: Opens full-screen SLA & Incident Dashboard displaying per-portal metrics and MTTR breakdown.

## System Requirements & Execution

### Prerequisites

* Windows 10, Windows 11, or Windows Server.
* Windows PowerShell 5.1 or PowerShell 7+.
* Network access to target portal URLs and public status endpoints (port 443 outbound).

### Execution

1. Open PowerShell (Admin privileges are optional; KeepAlive operates with standard user rights).
2. Navigate to the project root directory:

```powershell
cd C:\Path\To\MonitorPortales
```

3. Launch the orchestrator script:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\monitor.ps1
```

To stop the monitor safely, press `Ctrl + C`. The `finally` block executes automatically, restoring Windows power management and unhiding the cursor.

## Operational Architecture & Resiliency

### 1. Screen Lock & Sleep Resilience

In Windows corporate environments, locking the screen (`Win + L`) or workstation inactivity can cause network interfaces to enter power-saving states or drop VPN tunnels momentarily. `Network.ps1` implements safe exception extraction (`$_.Exception.Status`), ensuring that network drops do not throw null-reference runtime exceptions, allowing the script to log connection drops gracefully and recover as soon as connectivity resumes.

### 2. Cadence & Overrun Management

If a scan takes longer than the configured interval (for instance, when multiple portals hit maximum timeouts simultaneously), the monitor detects the `OVERRUN` condition, logs an advisory message to console, introduces a brief 1-second pause to prevent CPU throttling, and begins the next sweep immediately without entering countdown deadlocks.

### 3. Telemetry Snapshots & Schema Continuity

Snapshots are appended to `history.csv` every 5 minutes. On startup, `Telemetry.ps1` reads the CSV, parses the last recorded state for each URL, and restores cumulative counters (`Success`, `Failure`, `Incidents`, `TotalDowntimeSec`), ensuring persistent metrics across system reboots or terminal restarts.
