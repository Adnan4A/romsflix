# Romsflix catalog demo — progress log

_Last updated: 2026-11-09_

Local test site that reads **axekin.com** (Laravel + Inertia game catalog), normalises its
IGDB-sourced title data, and renders a modern filterable catalog with a full per-title
download box (base / update / DLC links, copy, open, availability check).

- **Runtime:** PowerShell 5.1 (`System.Net.Sockets.TcpListener` + `curl.exe`), no Node/Python/php.
- **Entry point:** `server.ps1` → http://localhost:8090/
- **Status:** working. 21,129 titles / 32 platforms / 103 categories; every filter, pagination,
  deep-link hash, detail modal and link availability check verified in the browser.

---

## 1. What axekin.com is

Laravel behind **Inertia.js**, wrapped in an **Anubis** proof-of-work wall. There is no public
JSON API: the Inertia page props *are* the data. Every request needs the Anubis cookie (bound to
IP + User-Agent) and, for the JSON variant, Inertia headers.

```
GET https://www.axekin.com/games?page=N          # listing, 25 per page (fixed)
GET https://www.axekin.com/games/<slug>          # single game; key can be slug or titleId
POST https://www.axekin.com/api/games/check-links
```

Inertia request headers:

```
X-Inertia: true
Accept: application/json
X-Requested-With: XMLHttpRequest
X-Inertia-Version: <version>      # avoids the 409 asset-version round trip
```

`X-Inertia-Version` is cached in `data/version.txt`; a newer value in any response body
(`props.version` / top-level `version`) replaces it. A 409 body still parses as JSON.

## 2. Anubis proof-of-work

The wall serves an HTML page containing:

```html
<script id="anubis_challenge" type="application/json"> {...} </script>
```

with `challenge.id`, `challenge.randomData`, `challenge.difficulty` (leading zero **hex nibbles**).
Solve: SHA-256 over `randomData + nonce` until the digest has `difficulty/2` zero bytes
(and, for odd difficulty, a zero high nibble). Then:

```
GET /.within.website/x/cmd/anubis/api/pass-challenge
    ?id=<id>&response=<hex>&nonce=<n>&redir=<escaped url>&elapsedTime=<ms>
```

This sets `techaro.lol-anubis-auth-347ddb4a` and
`techaro.lol-anubis-cookie-verification-347ddb4a` in the cookie jar. Typical solve: ~0.3 s at
difficulty 4. `Repair-Session` re-solves automatically whenever a request comes back as HTML
instead of JSON; it also re-seeds the `XSRF-TOKEN` cookie (needed by check-links) with a plain
`GET /`.

**The UA must never change** — Anubis binds the cookie to it:

```
Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36
```

`Invoke-WebRequest` fails TLS against this host in this environment, so everything goes through
`curl.exe` with the persistent jar `data/cookies.txt`.

## 3. Data shape

Listing page props:

```
props.games.meta  = { total, perPage, currentPage, lastPage, from, to }
props.games.data  = [ game, ... ]              // 25 items
props.platforms   = [ { id, name, slug, type, manufacturer, sortOrder, icon } ]
props.genres      = [ { id, slug, name } ]     // 103 entries
props.regions     = [ { value, count } ]       // raw list has upstream typos
props.releaseYears= { min, max }
```

Per-game fields used by the UI (all IGDB-sourced where applicable):

| field | notes |
| --- | --- |
| `id`, `slug`, `title`, `alternativeName`, `titleId` | `titleId` = serial (CUSA…, 0100…); may be null |
| `igdbGameId` | links out to `https://www.igdb.com/games/<slug>` |
| `rating` | IGDB user rating, 0–10, one decimal |
| `metacriticScore` | 0–100, often null |
| `releaseDate` | ISO date; `year` derived from it |
| `region` | `NA`, `EU`, `JP`, `AS`, `WW`, … |
| `coverImage`, `bannerImage` | relative `/uploads/...` paths |
| `description` | HTML, cleaned to plain text (max 1600 chars) |
| `platforms[]`, `genres[]`, `developers[]`, `publishers[]` | objects / names |
| `downloadLinks[]` | `{ url, type }`, type ∈ `base` \| `update` \| `dlc` |

**The download box is already in the listing payload.** No extra detail request is needed to
open a modal — the local `/api/game` endpoint exists only for slug/titleId lookups and deep links.

## 4. Upstream filters (all verified)

Query params on `/games`:

| param | behaviour |
| --- | --- |
| `platform` | slug (`switch`, `ps4`, `nes`, …) |
| `genre` | numeric genre IDs, comma-separated, **max 5**, **AND** semantics |
| `region` | case-sensitive exact value (`EU`, `NA`, …) |
| `sort` | `newest` \| `title` \| `rating` \| `downloads` |
| `search` | free text |
| `min_rating` | 0–10 |
| `min_metascore` | 0–100 |
| `year_from`, `year_to` | release year range |
| `has_dlc=1`, `has_update=1` | presence flags |
| `page` | page size is **fixed at 25**; `per_page` is ignored |

Reference counts (live, 2026-11-09):

| query | total |
| --- | ---: |
| all | 21,129 (846 pages) |
| `platform=switch` | 1,260 |
| `platform=ps4` | 236 |
| `genre=1` (Action) | 3,971 |
| `genre=1,2` (Action AND Adventure) | 1,607 (65 pages) |
| `search=zelda` | 42 |
| `region=EU&min_rating=8` | 327 |
| `has_dlc=1` | 597 |
| `has_update=1&min_metascore=90` | 36 |
| `platform=ps4&genre=1,2&sort=downloads` | 111 |
| `year_from=2025&year_to=2026` | 530 |
| `min_rating=9&year_from=1970&year_to=1970` | 0 (empty state) |

## 5. Link availability check

```
POST /api/games/check-links
Content-Type: application/json
X-XSRF-TOKEN: <url-decoded XSRF-TOKEN cookie>
Origin: https://www.axekin.com

{ "urls": ["https://...", ...] }
```

Returns `[{ url, status, name?, size? }]` with `status ∈ online | offline | unsupported`,
`size` in bytes. Rate limit ~30/min, so the UI checks at most **15 links per call** and only for
the currently visible tab. The XSRF cookie is seeded by a plain HTML `GET /` (`Get-XsrfToken`).

Example (Driveclub): 18 links total → 2 base, 2 update, 14 DLC. DLC tab check: 14/14 checked,
10 online, 2 offline, 2 unsupported.

## 6. Local server (`server.ps1`)

```
GET /                     index.html
GET /health               { ok, version, session }
GET /api/bootstrap        counts + platforms + genres + regions + years + featured + first page
GET /api/games            page, platform, genre, region, sort, search,
                          min_rating, min_metascore, year_from, year_to, has_dlc, has_update
GET /api/game?key=        slug or titleId → one normalised game
GET /api/check-links?urls=<json array>
GET /img?p=<relative /uploads path>
```

- **Cache:** in-memory, 10 minutes, keyed by the full filter tuple. `?refresh=1` bypasses.
  Cached games response ≈ 128 ms / 56 KB; cold ≈ 1.5–4.5 s (upstream + Anubis).
- **Images:** proxied and disk-cached in `data/img/` (SHA-1 filename). Each listing is pre-warmed
  with one `curl --parallel --parallel-max 10` call, so the grid paints immediately. Paths are
  restricted to `^/uploads/`.
- **Normalisation:** HTML descriptions are stripped to text; links get a `host` label and a
  base/update/dlc/other count; `cover`/`banner` become local `/img?p=…` URLs; `igdb` and `page`
  point at the public sites.

## 7. Front end (`index.html`)

Single file, no dependencies, dark UI.

- Hero: live stat tiles (titles / platforms / 103 categories / 9 main regions), featured title
  card, search box.
- Platform chips (32, short labels e.g. `Switch`, `PS4`, `GBA`), category popover with search,
  max-5 multi-select, region/sort/rating/metascore/year/DLC/update filters, removable
  active-filter chips.
- Card grid: cover, IGDB rating badge, link count, MC badge, platform abbreviations.
- Deep-linkable state in the URL hash (`#platform=ps4&genre=1,2&page=2`); back/forward works.
  Per-title links work too: `#game=CUSA00093` or `#game=<slug>` opens that title's modal
  (falls back to `/api/game` when the title is not on the current page). Closing the modal
  clears the `game` key.
- Skeleton loading, empty state with “Clear filters”, pagination with ellipses.
- Detail modal: banner + cover, stat strip (rating, MC, released, region, version, size,
  downloads, title ID), description, categories, links to Axekin/IGDB, and the download box with
  `All / Base / Update / DLC` tabs, per-row Copy + Open, and availability badges
  (`ONLINE` / `OFFLINE` / `N/A` + size).

## 8. Bugs fixed during the build

- `$Page` is an `[int]` parameter in `Get-GamesData`; reusing `$page` for the JSON document made
  PowerShell try to convert a `PSCustomObject` to `Int32` (“Cannot convert … to type System.Int32”).
  The document variable is now `$doc`.
- Nested `if … else` expressions inside hashtable literals break in PS 5.1 — compute values into
  locals first.
- The genre count badge stayed visible at `0` because `[hidden]` lost to `display:inline-grid`;
  fixed with `.genre-btn .count[hidden]{display:none}`.
- Genre checkbox changes rebuilt the whole popover and killed clicks/focus mid-interaction;
  now `updateGenreUi()` only toggles the disabled state.
- **Card covers never painted**: `.cover-fallback` is absolutely positioned, so it stacked above
  the non-positioned `<img>`. Fixed with `.cover img{position:absolute;inset:0;z-index:1}`.
- Region list contains upstream typos (`E`, `E U`, `E>U`, `EU, AS`, `EY`, `NA - JP`); the UI only
  offers the 10 real codes.
- Availability check used the first 15 links of the whole game; it now uses the visible tab.

## 9. File layout

```
romsflix/
  server.ps1        local proxy/server (port 8090)
  index.html        single-file UI
  probe.ps1         standalone Anubis solve + Inertia fetch proof
  tmp/              challenge.html, page.json, check bodies (transient)
  data/
    cookies.txt     Anubis + XSRF session jar (UA-bound, recreated on demand)
    version.txt     cached Inertia asset version
    img/            image cache
```

## 10. Restart

```powershell
Get-NetTCPConnection -LocalPort 8090 -State Listen -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\thead\Documents\Default Project\romsflix\server.ps1" -Port 8090
```

Then open http://localhost:8090/. A cold start re-solves Anubis automatically (~0.3 s) the first
time any upstream call is made.

## 11. Caveats

- The Anubis session expires; the server re-solves on demand, but a request that lands during
  re-solve takes ~1–2 s longer the first time.
- The cookie jar is UA-bound — changing the UA string invalidates it (`Max-Age=0` + challenge).
- Upstream page size is fixed at 25, so `lastPage` is the only pagination authority.
- Check-links is rate-limited (~30/min) and unsupported for some hosts by design; the UI labels
  those `N/A` instead of pretending they are dead.
- Axekin data changes upstream; counts in this document are a snapshot.

## 12. Last edits

- 2026-11-09: renamed the project from `axekin-test` to `romsflix`; UI rebranded to
  **ROMSFLIX** (title, top bar, error copy, console banner), data-source attribution to
  axekin.com kept in the footer. Added per-title deep links (`#game=<slug|titleId>`).
- 2026-11-09: fixed card cover stacking (positioned fallback hid every cover), genre badge
  `[hidden]`, genre popover focus loss, per-tab availability checks, status badges
  (`online/offline/n-a`), short platform labels, main-region-only select, live search
  placeholders, skeleton shown before bootstrap, singular “1 title”. Final end-to-end pass:
  empty state, slug-keyed `/api/game`, 404s for bad image paths and bad keys.
