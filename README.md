# Romsflix

A modern game catalog over **axekin.com**'s IGDB-sourced title records, with a per-title
download box (base / update / DLC links, copy, open, availability check).

Everything runs on PowerShell 5.1 (`System.Net.Sockets.TcpListener` + `curl.exe`) — no Node,
Python, PHP or database.

## Run

```powershell
Get-NetTCPConnection -LocalPort 8090 -State Listen -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\server.ps1 -Port 8090
```

Open http://localhost:8090/

Deep links: `http://localhost:8090/#game=CUSA00093`,
`http://localhost:8090/#platform=ps4&genre=1,2&page=2`.

## What it does

- Solves the Anubis proof-of-work wall server-side (SHA-256, ~0.3 s at difficulty 4) and keeps
  the UA-bound cookie jar alive.
- Reads Inertia page props directly: 21,129 titles, 32 platforms, 103 categories.
- Normalises IGDB-sourced fields: rating, metacritic, release date, genres, platforms,
  developers, cover/banner, description; links each title to its IGDB page.
- Proxies and disk-caches images, and pre-warms each page's covers with one parallel `curl` call.
- Download box tabs `All / Base / Update / DLC`, per-link Copy and Open, plus an availability
  check against Axekin's `/api/games/check-links` (`ONLINE` / `OFFLINE` / `N/A` + size).

## Files

| file | purpose |
| --- | --- |
| `server.ps1` | local server: Anubis session, Inertia fetches, filters, image cache, check-links |
| `index.html` | single-file UI: hero, filters, grid, modal, download box |
| `probe.ps1` | standalone Anubis solve + Inertia fetch proof |
| `romsflix.md` | full technical notes: upstream API, filters, endpoints, bugs, verification |

## Notes

- `data/` (cookies, cached images, transient JSON) and `tmp/` are runtime state and git-ignored.
- The Anubis cookie is tied to the exact Chrome 152 user agent in `server.ps1`; changing it
  invalidates the session (the server re-solves automatically).
- Upstream page size is fixed at 25 titles per page.
