# webMonitor

Live web page monitor — a PowerShell console dashboard for preventive portal monitoring in a NOC / IT operations shift.

It checks a list of web portals on a schedule, classifies each one, and shows a live table with status, latency, a 10-check timeline, and real-time uptime % per portal. It also watches Azure and Palo Alto SASE cloud health, logs every outage with its downtime duration, and keeps its history across PC reboots.

## Features

- **Portal health checks** — HTTP GET per portal with an 8 s timeout, TLS 1.2/1.3, every 120 s (configurable).
- **Smart status classification**
  - `ONLINE` — HTTP 200
  - `AUTH/SSO` — 301/302/307/308 redirect to login / SSO
  - `AUTH REQ` — 401/403, corporate authentication required
  - `DEGRADED` — response slower than 3.5 s
  - `SRV ERROR` — HTTP 5xx
  - `DNS FAIL`, `TIMEOUT`, `SSL FAIL`, `REFUSED`, `UNREACHABLE` — network-level failures
- **Live dashboard** — status, HTTP code, latency, 10-check timeline sparkline (`O` ok / `X` fail), OK/NO counters, and uptime % per portal (green ≥ 99%, yellow ≥ 95%, red below).
- **Cloud health** — Azure status feed and Palo Alto Networks SASE status API (Prisma Access / GlobalProtect), with a detailed SASE incidents and components view.
- **Outage logging** — `outages.log` records every outage detection and resolution, including downtime duration.
- **Persistent history** — counters auto-snapshot to `history.csv` every 5 minutes and are restored on restart, so uptime survives reboots.
- **KeepAlive (dual engine)** — prevents the PC from sleeping while monitoring: `kernel32 SetThreadExecutionState` API, with an F15 virtual-key fallback.
- **Hotkeys** — `[1]` change interval · `[2]` edit portal list · `[3]` force scan · `[4]` open outages log · `[5]` open CSV database · `[6]` SASE details.
- **Color coding** — Core portals in orange, TCS support portals in cyan.

## Requirements

- Windows with Windows PowerShell 5.1 (or PowerShell 7+)
- Network/VPN access to the portals being monitored
- A `portales.txt` file next to the script (see below)

## Configuration

Create a `portales.txt` file in the same folder as `monitor.ps1`. One portal per line:

```text
Portal Name,https://portal.example.com
Support Portal,https://support.example.com,S
```

- Format: `Name,URL` — add `,S` as a third field to mark a TCS support portal (cyan) instead of a core portal (orange).
- Lines starting with `#` and empty lines are ignored.
- The script exits with an error if `portales.txt` is missing.

## Usage

```powershell
.\monitor.ps1
```

Press `Ctrl+C` to stop. Power management is restored on exit.

## Files

| File | Description |
| --- | --- |
| `monitor.ps1` | The monitor (v4.1 NOC Database Edition) |
| `portales.txt` | Portal list — you create it, not included in the repo |
| `history.csv` | Auto-generated telemetry database (5-minute snapshots) |
| `outages.log` | Auto-generated outage and incident audit log |

## Notes

- Scan interval default is 120 seconds; snapshot interval is 5 minutes; request timeout is 8 seconds — all configurable at the top of `monitor.ps1`.
- Latency over 3.5 s counts as degraded even when the portal answers with HTTP 200.
- `portales.txt`, `history.csv`, and `outages.log` are local runtime files and are intentionally not committed.
