param(
    [int]$Port = 8090,
    [int]$CacheMinutes = 10
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- config

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'
$tmpDir  = Join-Path $dataDir 'tmp'
$imgDir  = Join-Path $dataDir 'img'
foreach ($d in @($dataDir, $tmpDir, $imgDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$script:base        = 'https://www.axekin.com'
$script:ua          = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36'
$script:jar         = Join-Path $dataDir 'cookies.txt'
$script:versionFile = Join-Path $dataDir 'version.txt'
$script:tmp         = $tmpDir

$script:version   = 'a25272e36854659479879408bfdc0392'
if (Test-Path $script:versionFile) {
    $saved = (Get-Content -Raw $script:versionFile).Trim()
    if ($saved) { $script:version = $saved }
}
$script:apiCache  = @{}
$script:xsrf      = $null
$script:lastRepair = [datetime]::MinValue

# ---------------------------------------------------------------- upstream plumbing

function Invoke-Curl {
    param([string[]]$Arguments, [switch]$AllowFail)

    $out = & curl.exe @Arguments 2>$null
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) {
        throw "curl exited with $code"
    }
    return ($out -join "`n")
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Test-ImageBytes {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 12
            $n = $fs.Read($buf, 0, 12)
        }
        finally { $fs.Dispose() }
        if ($n -lt 4) { return $false }
        $ascii = [Text.Encoding]::ASCII.GetString($buf, 0, [Math]::Min($n, 12))
        if ($ascii.StartsWith('RIFF')) { return $true }
        if ($ascii.StartsWith([char]0x89 + 'PNG')) { return $true }
        if ($ascii.StartsWith('GIF8')) { return $true }
        if ($buf[0] -eq 0xFF -and $buf[1] -eq 0xD8) { return $true }
        return $false
    }
    catch { return $false }
}

# Anubis proof-of-work: SHA-256 over randomData + nonce, difficulty leading hex zeros.
function Repair-Session {
    param([switch]$Force)

    if (-not $Force -and ((Get-Date) - $script:lastRepair).TotalSeconds -lt 3) {
        throw 'Anubis repair attempted too recently'
    }
    $script:lastRepair = (Get-Date)

    $challengeFile = Join-Path $script:tmp 'challenge.html'
    $probeUrl = "$script:base/games?page=1"

    Invoke-Curl @('-s', '-A', $script:ua, '-b', $script:jar, '-c', $script:jar,
        '-H', 'Accept: text/html,application/xhtml+xml',
        '-o', $challengeFile, '--max-time', '60', $probeUrl) -AllowFail | Out-Null

    $content = Read-TextFile $challengeFile
    if ($content.TrimStart().StartsWith('{')) { return }

    $m = [regex]::Match($content, '<script id="anubis_challenge" type="application/json">(.*?)</script>', 'Singleline')
    if (-not $m.Success) {
        if ($content -match '<!DOCTYPE html' -or $content -match '<html') {
            # Already authorised: the HTML page is the real site.
            Get-XsrfToken -Refresh | Out-Null
            return
        }
        throw 'Anubis challenge not found in response'
    }

    $ch       = $m.Groups[1].Value | ConvertFrom-Json
    $rand     = [string]$ch.challenge.randomData
    $difficulty = [int]$ch.challenge.difficulty
    $id       = [string]$ch.challenge.id
    if (-not $rand -or -not $id) { throw 'Anubis challenge is missing fields' }

    $sha       = [Security.Cryptography.SHA256]::Create()
    $fullBytes = [Math]::Floor($difficulty / 2)
    $odd       = ($difficulty % 2) -ne 0
    $nonce     = 0
    $hex       = $null
    $sw        = [Diagnostics.Stopwatch]::StartNew()

    while ($true) {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($rand + $nonce))
        $ok = $true
        for ($i = 0; $i -lt $fullBytes; $i++) { if ($hash[$i] -ne 0) { $ok = $false; break } }
        if ($ok -and $odd -and (($hash[$fullBytes] -band 0xF0) -ne 0)) { $ok = $false }
        if ($ok) {
            $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
            break
        }
        $nonce++
        if ($nonce -ge 50000000) { throw 'Anubis nonce limit exceeded' }
    }
    $sw.Stop()

    $redir   = [Uri]::EscapeDataString($probeUrl)
    $passUrl = "$script:base/.within.website/x/cmd/anubis/api/pass-challenge?id=$id&response=$hex&nonce=$nonce&redir=$redir&elapsedTime=$([int]$sw.Elapsed.TotalMilliseconds)"
    Invoke-Curl @('-s', '-A', $script:ua, '-b', $script:jar, '-c', $script:jar,
        '-o', (Join-Path $script:tmp 'pass.html'), '--max-time', '60', $passUrl) -AllowFail | Out-Null

    Get-XsrfToken -Refresh | Out-Null
    Write-Host ("Anubis solved: difficulty=$difficulty nonce=$nonce in {0:n2}s" -f $sw.Elapsed.TotalSeconds)
}

function Get-XsrfToken {
    param([switch]$Refresh)

    if (-not $Refresh -and $script:xsrf) { return $script:xsrf }
    $script:xsrf = $null
    if (-not (Test-Path $script:jar)) { return $null }

    # A plain HTML GET seeds the XSRF-TOKEN cookie.
    Invoke-Curl @('-s', '-A', $script:ua, '-b', $script:jar, '-c', $script:jar,
        '-o', (Join-Path $script:tmp 'home.html'), '--max-time', '60', "$script:base/") -AllowFail | Out-Null

    $line = Get-Content $script:jar -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "`tXSRF-TOKEN`t" } | Select-Object -Last 1
    if (-not $line) { return $null }
    $parts = $line -split "`t"
    if ($parts.Count -lt 7) { return $null }
    try { $script:xsrf = [Uri]::UnescapeDataString($parts[6]) } catch { $script:xsrf = $parts[6] }
    return $script:xsrf
}

# Fetch an Inertia page as JSON. Repairs the Anubis session once on challenge.
function Invoke-AxekinJson {
    param([string]$Query)

    $url = "$script:base/games?$Query"
    $out = Join-Path $script:tmp 'page.json'

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        Remove-Item $out -Force -ErrorAction SilentlyContinue
        $argv = @('-s', '-A', $script:ua, '-b', $script:jar, '-c', $script:jar,
            '-H', 'X-Inertia: true',
            '-H', 'Accept: application/json',
            '-H', 'X-Requested-With: XMLHttpRequest',
            '-o', $out, '--max-time', '90')
        if ($script:version) { $argv += @('-H', "X-Inertia-Version: $($script:version)") }
        $argv += $url
        Invoke-Curl $argv -AllowFail | Out-Null

        $raw = Read-TextFile $out
        if ($raw.TrimStart().StartsWith('{')) {
            $page = $raw | ConvertFrom-Json
            if ($page.PSObject.Properties['version'] -and $page.version) {
                $script:version = [string]$page.version
                [IO.File]::WriteAllText($script:versionFile, $script:version, [Text.Encoding]::ASCII)
            }
            return $page
        }
        if ($attempt -eq 0) { Repair-Session }
    }
    throw 'Axekin returned a non-JSON response'
}

# Fetch a game page (the download box lives in props.game.downloadLinks).
function Invoke-AxekinGame {
    param([string]$Key)

    if ($Key -notmatch '^[A-Za-z0-9_\-\.]+$') { throw 'invalid game key' }

    $out = Join-Path $script:tmp 'game.json'
    $url = "$script:base/games/$Key"

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        Remove-Item $out -Force -ErrorAction SilentlyContinue
        $argv = @('-s', '-A', $script:ua, '-b', $script:jar, '-c', $script:jar,
            '-H', 'X-Inertia: true',
            '-H', 'Accept: application/json',
            '-H', 'X-Requested-With: XMLHttpRequest',
            '-o', $out, '--max-time', '90')
        if ($script:version) { $argv += @('-H', "X-Inertia-Version: $($script:version)") }
        $argv += $url
        Invoke-Curl $argv -AllowFail | Out-Null

        $raw = Read-TextFile $out
        if ($raw.TrimStart().StartsWith('{')) {
            $page = $raw | ConvertFrom-Json
            if ($page.PSObject.Properties['version'] -and $page.version) {
                $script:version = [string]$page.version
                [IO.File]::WriteAllText($script:versionFile, $script:version, [Text.Encoding]::ASCII)
            }
            return $page
        }
        if ($attempt -eq 0) { Repair-Session }
    }
    throw 'Axekin returned a non-JSON response'
}

# ---------------------------------------------------------------- images

function Get-ImageExt {
    param([string]$Path)
    $clean = ($Path -split '\?')[0]
    $ext = [IO.Path]::GetExtension($clean).ToLowerInvariant()
    switch ($ext) {
        '.webp' { return '.webp' }
        '.jpg'  { return '.jpg'  }
        '.jpeg' { return '.jpg'  }
        '.png'  { return '.png'  }
        '.gif'  { return '.gif'  }
        '.avif' { return '.avif' }
        default { return '.img'  }
    }
}

function Get-ImageFile {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path)) | ForEach-Object { $_.ToString('x2') })
    }
    finally { $sha.Dispose() }
    return Join-Path $imgDir ($hash + (Get-ImageExt $Path))
}

function Get-ImageContentType {
    param([string]$File)
    switch ([IO.Path]::GetExtension($File).ToLowerInvariant()) {
        '.webp' { return 'image/webp' }
        '.jpg'  { return 'image/jpeg' }
        '.png'  { return 'image/png'  }
        '.gif'  { return 'image/gif'  }
        '.avif' { return 'image/avif' }
        default { return 'application/octet-stream' }
    }
}

# Download a batch of upstream images in parallel with one curl invocation.
function Save-Images {
    param([string[]]$Paths)

    $todo = @()
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        if ($p -notmatch '^/uploads/') { continue }
        $file = Get-ImageFile $p
        if ((Test-Path $file) -and (Test-ImageBytes $file)) { continue }
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        $todo += [pscustomobject]@{ path = $p; file = $file }
    }
    if ($todo.Count -eq 0) { return }

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $argv = @('-s', '-A', $script:ua, '-b', $script:jar,
            '--parallel', '--parallel-max', '10', '--max-time', '90')
        foreach ($t in $todo) {
            $argv += @('-o', $t.file, ($script:base + $t.path))
        }
        Invoke-Curl $argv -AllowFail | Out-Null

        $bad = @($todo | Where-Object { -not (Test-ImageBytes $_.file) })
        if ($bad.Count -eq 0) { return }
        foreach ($b in $bad) { Remove-Item $b.file -Force -ErrorAction SilentlyContinue }
        if ($attempt -eq 0) { Repair-Session }
        $todo = $bad
    }
}

# ---------------------------------------------------------------- normalisation

function Get-HostLabel {
    param([string]$Url)
    try {
        $h = ([Uri]$Url).Host.ToLowerInvariant()
        if ($h.StartsWith('www.')) { $h = $h.Substring(4) }
        return $h
    }
    catch { return 'link' }
}

function Get-CleanDescription {
    param([string]$Html)
    if ([string]::IsNullOrEmpty($Html)) { return '' }
    $text = [regex]::Replace($Html, '(?is)<(script|style).*?</\1>', ' ')
    $text = [regex]::Replace($text, '(?i)<br\s*/?>', "`n")
    $text = [regex]::Replace($text, '</p>', "`n")
    $text = [regex]::Replace($text, '<[^>]+>', ' ')
    $text = [Net.WebUtility]::HtmlDecode($text)
    $text = [regex]::Replace($text, '[ \t]+', ' ')
    $text = [regex]::Replace($text, '(\r?\n\s*){2,}', "`n")
    return $text.Trim()
}

function ConvertTo-GameItem {
    param($Game)

    $cover  = [string]$Game.coverImage
    $banner = [string]$Game.bannerImage
    if ($cover  -and $cover  -notmatch '^/uploads/') { $cover  = '' }
    if ($banner -and $banner -notmatch '^/uploads/') { $banner = '' }

    $links  = @()
    $counts = @{ base = 0; update = 0; dlc = 0; other = 0 }
    foreach ($l in @($Game.downloadLinks)) {
        if (-not $l -or -not $l.url) { continue }
        $type = ([string]$l.type).ToLowerInvariant()
        if (-not $counts.ContainsKey($type)) { $type = 'other' }
        $counts[$type]++
        $links += [pscustomobject]@{
            url  = [string]$l.url
            type = $type
            host = (Get-HostLabel ([string]$l.url))
        }
    }

    $rating = $null
    $r = 0.0
    if ([double]::TryParse([string]$Game.rating, [ref]$r)) { $rating = [Math]::Round($r, 1) }

    $meta = $null
    $mi = 0
    if ([int]::TryParse([string]$Game.metacriticScore, [ref]$mi) -and $mi -gt 0) { $meta = $mi }

    $release = [string]$Game.releaseDate
    $year = $null
    if ($release -match '^(\d{4})') { $year = [int]$Matches[1] }

    $plats = @(
        foreach ($p in @($Game.platforms)) {
            if (-not $p) { continue }
            [pscustomobject]@{ slug = [string]$p.slug; name = [string]$p.name; type = [string]$p.type }
        }
    )
    $gens = @(
        foreach ($g in @($Game.genres)) {
            if (-not $g) { continue }
            [pscustomobject]@{ id = [int]$g.id; slug = [string]$g.slug; name = [string]$g.name }
        }
    )
    $devs = @($Game.developers | Where-Object { $_ } | ForEach-Object { [string]$_.name })
    $pubs = @($Game.publishers | Where-Object { $_ } | ForEach-Object { [string]$_.name })

    $desc = Get-CleanDescription ([string]$Game.description)
    if ($desc.Length -gt 1600) { $desc = $desc.Substring(0, 1600).TrimEnd() + '…' }

    $altTitle = $null
    if ($Game.alternativeName) { $altTitle = [string]$Game.alternativeName }

    $titleId = $null
    if ($Game.titleId) { $titleId = [string]$Game.titleId }

    $igdbId = $null
    if ($Game.igdbGameId) { $igdbId = [int]$Game.igdbGameId }

    $coverUrl  = $null
    $bannerUrl = $null
    if ($cover)  { $coverUrl  = '/img?p=' + [Uri]::EscapeDataString($cover) }
    if ($banner) { $bannerUrl = '/img?p=' + [Uri]::EscapeDataString($banner) }

    return [pscustomobject]@{
        id            = [int]$Game.id
        title         = [string]$Game.title
        altTitle      = $altTitle
        slug          = [string]$Game.slug
        titleId       = $titleId
        igdbGameId    = $igdbId
        rating        = $rating
        metacritic    = $meta
        releaseDate   = $release
        year          = $year
        region        = [string]$Game.region
        fileSize      = [string]$Game.fileSize
        version       = [string]$Game.version
        downloadCount = [int]$Game.downloadCount
        cover         = $coverUrl
        banner        = $bannerUrl
        coverPath     = $cover
        bannerPath    = $banner
        description   = $desc
        developers    = @($devs)
        publishers    = @($pubs)
        platforms     = @($plats)
        genres        = @($gens)
        links         = @($links)
        linkCounts    = [pscustomobject]@{
            base   = $counts.base
            update = $counts.update
            dlc    = $counts.dlc
            other  = $counts.other
            total  = $links.Count
        }
        page          = "$($script:base)/games/$([string]$Game.slug)"
        igdb          = "https://www.igdb.com/games/$([string]$Game.slug)"
    }
}

function Get-CacheItem {
    param([string]$Key)
    if (-not $script:apiCache.ContainsKey($Key)) { return $null }
    $entry = $script:apiCache[$Key]
    if (((Get-Date) - $entry.at).TotalMinutes -ge $CacheMinutes) {
        $script:apiCache.Remove($Key)
        return $null
    }
    return $entry.data
}

function Set-CacheItem {
    param([string]$Key, $Data)
    $script:apiCache[$Key] = @{ at = (Get-Date); data = $Data }
}

# ---------------------------------------------------------------- data access

function New-GamesEnvelope {
    param($Page, $Filters)

    $props = $Page.props
    $meta  = $props.games.meta
    $raw   = @($props.games.data)

    $items = @(
        foreach ($g in $raw) {
            if (-not $g) { continue }
            ConvertTo-GameItem $g
        }
    )

    # Warm the cover cache in one parallel curl call so the grid paints instantly.
    $covers = @($items | ForEach-Object { $_.coverPath } | Where-Object { $_ })
    if ($covers.Count -gt 0) {
        try { Save-Images $covers } catch { }
    }

    return [pscustomobject]@{
        page       = [int]$meta.currentPage
        total      = [int]$meta.total
        totalPages = [int]$meta.lastPage
        count      = $items.Count
        filters    = $Filters
        items      = @($items)
    }
}

function Get-GamesData {
    param(
        [int]$Page = 1,
        [string]$Platform = '',
        [string]$Genre = '',
        [string]$Region = '',
        [string]$Sort = 'newest',
        [string]$Search = '',
        [int]$MinRating = 0,
        [int]$MinMetacritic = 0,
        [int]$YearFrom = 0,
        [int]$YearTo = 0,
        [bool]$HasDlc = $false,
        [bool]$HasUpdate = $false,
        [switch]$Force
    )

    if ($Page -lt 1) { $Page = 1 }
    $allowedSort = @('newest', 'title', 'rating', 'downloads')
    if ($allowedSort -notcontains $Sort) { $Sort = 'newest' }

    if ($Platform -and $Platform -notmatch '^[a-z0-9\-]+$') { $Platform = '' }
    $Genre = (@($Genre -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 5) -join ',')
    if ($Region -and $Region -notmatch '^[A-Za-z0-9 ,\->]+$') { $Region = '' }
    if ($YearFrom -lt 1970) { $YearFrom = 0 }
    if ($YearTo   -lt 1970) { $YearTo   = 0 }

    $key = 'games|{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}' -f `
        $Page, $Platform, $Genre, $Region, $Sort, $Search.ToLowerInvariant(), $MinRating, $MinMetacritic, $YearFrom, $YearTo, $HasDlc, $HasUpdate
    if (-not $Force) {
        $hit = Get-CacheItem $key
        if ($hit) { return $hit }
    }

    $parts = @("page=$Page")
    if ($Platform) { $parts += 'platform=' + [Uri]::EscapeDataString($Platform) }
    if ($Genre)    { $parts += 'genre='    + [Uri]::EscapeDataString($Genre) }
    if ($Region)   { $parts += 'region='   + [Uri]::EscapeDataString($Region) }
    if ($Sort -ne 'newest') { $parts += 'sort=' + [Uri]::EscapeDataString($Sort) }
    if ($Search)   { $parts += 'search='   + [Uri]::EscapeDataString($Search) }
    if ($MinRating -gt 0)     { $parts += "min_rating=$MinRating" }
    if ($MinMetacritic -gt 0) { $parts += "min_metascore=$MinMetacritic" }
    if ($YearFrom -gt 0)      { $parts += "year_from=$YearFrom" }
    if ($YearTo -gt 0)        { $parts += "year_to=$YearTo" }
    if ($HasDlc)    { $parts += 'has_dlc=1' }
    if ($HasUpdate) { $parts += 'has_update=1' }

    $filters = [pscustomobject]@{
        platform      = $Platform
        genre         = $Genre
        region        = $Region
        sort          = $Sort
        search        = $Search
        minRating     = $MinRating
        minMetacritic = $MinMetacritic
        yearFrom      = $YearFrom
        yearTo        = $YearTo
        hasDlc        = $HasDlc
        hasUpdate     = $HasUpdate
    }

    # NOTE: $Page is an [int]; never reuse the name for the JSON document.
    $doc  = Invoke-AxekinJson ($parts -join '&')
    $data = New-GamesEnvelope -Page $doc -Filters $filters
    Set-CacheItem $key $data
    return $data
}

function Get-BootstrapData {
    param([switch]$Force)

    if (-not $Force) {
        $hit = Get-CacheItem 'bootstrap'
        if ($hit) { return $hit }
    }

    # Pull the first listing page plus the option lists in one request.
    $page  = Invoke-AxekinJson 'page=1'
    $props = $page.props
    $defaultFilters = [pscustomobject]@{
        platform      = ''
        genre         = ''
        region        = ''
        sort          = 'newest'
        search        = ''
        minRating     = 0
        minMetacritic = 0
        yearFrom      = 0
        yearTo        = 0
        hasDlc        = $false
        hasUpdate     = $false
    }
    $games = New-GamesEnvelope -Page $page -Filters $defaultFilters
    Set-CacheItem 'games|1||||newest||0|0|0|0|False|False' $games

    $platforms = @(
        $props.platforms |
            Sort-Object { [int]$_.sortOrder }, { [string]$_.name } |
            ForEach-Object {
                $maker = ''
                if ($_.manufacturer) { $maker = [string]$_.manufacturer }
                [pscustomobject]@{
                    slug         = [string]$_.slug
                    name         = [string]$_.name
                    type         = [string]$_.type
                    manufacturer = $maker
                }
            }
    )
    $genres = @(
        $props.genres |
            Sort-Object { [string]$_.name } |
            ForEach-Object {
                [pscustomobject]@{ id = [int]$_.id; slug = [string]$_.slug; name = [string]$_.name }
            }
    )
    $regions = @(
        $props.regions |
            Where-Object { [int]$_.count -gt 0 } |
            Sort-Object { [int]$_.count } -Descending |
            ForEach-Object {
                [pscustomobject]@{ value = [string]$_.value; count = [int]$_.count }
            }
    )

    $featured = $null
    if ($games.items.Count -gt 0) { $featured = $games.items[0] }
    # Prefetch the hero banner too.
    if ($featured -and $featured.bannerPath) {
        try { Save-Images @($featured.bannerPath) } catch { }
    }

    $data = [pscustomobject]@{
        totalGames = $games.total
        platforms  = @($platforms)
        genres     = @($genres)
        regions    = @($regions)
        years      = [pscustomobject]@{
            min = [int]$props.releaseYears.min
            max = [int]$props.releaseYears.max
        }
        sorts      = @('newest', 'title', 'rating', 'downloads')
        source     = 'https://www.axekin.com/games'
        featured   = $featured
        games      = $games
    }
    Set-CacheItem 'bootstrap' $data
    return $data
}

# ---------------------------------------------------------------- http helpers

function Send-Response {
    param(
        $Stream,
        [int]$Status = 200,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [byte[]]$Body = @(),
        [hashtable]$Headers = @{},
        [switch]$HeadOnly
    )

    $reasons = @{
        200 = 'OK'; 204 = 'No Content'; 301 = 'Moved Permanently'; 302 = 'Found'
        304 = 'Not Modified'; 400 = 'Bad Request'; 404 = 'Not Found'; 405 = 'Method Not Allowed'
        409 = 'Conflict'; 419 = 'Authentication Timeout'; 429 = 'Too Many Requests'
        500 = 'Internal Server Error'; 502 = 'Bad Gateway'; 503 = 'Service Unavailable'
    }
    $reason = if ($reasons.ContainsKey($Status)) { $reasons[$Status] } else { 'OK' }

    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $Status $reason`r`n")
    [void]$sb.Append("Content-Type: $ContentType`r`n")
    [void]$sb.Append("Content-Length: $($Body.Length)`r`n")
    if (-not $Headers.ContainsKey('Cache-Control')) { [void]$sb.Append("Cache-Control: no-store`r`n") }
    [void]$sb.Append("Access-Control-Allow-Origin: *`r`n")
    [void]$sb.Append("X-Content-Type-Options: nosniff`r`n")
    [void]$sb.Append("Connection: close`r`n")
    foreach ($k in $Headers.Keys) { [void]$sb.Append("$k`: $($Headers[$k])`r`n") }
    [void]$sb.Append("`r`n")

    $head = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Stream.Write($head, 0, $head.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-Json {
    param($Stream, $Data, [int]$Status = 200, [hashtable]$Headers = @{}, [switch]$HeadOnly)

    $json = ConvertTo-Json -InputObject $Data -Depth 12 -Compress
    Send-Response -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) -Headers $Headers -HeadOnly:$HeadOnly
}

function Send-Error {
    param($Stream, [int]$Status, [string]$Message, [switch]$HeadOnly)
    Send-Json $Stream ([pscustomobject]@{ error = $Message }) -Status $Status -HeadOnly:$HeadOnly
}

function Get-QueryMap {
    param([string]$QueryString)

    $map = @{}
    if ([string]::IsNullOrEmpty($QueryString)) { return $map }
    foreach ($pair in $QueryString.Split('&')) {
        if (-not $pair) { continue }
        $i = $pair.IndexOf('=')
        if ($i -lt 0) {
            $map[[Uri]::UnescapeDataString($pair)] = ''
        }
        else {
            $k = [Uri]::UnescapeDataString($pair.Substring(0, $i))
            $v = [Uri]::UnescapeDataString($pair.Substring($i + 1).Replace('+', ' '))
            $map[$k] = $v
        }
    }
    return $map
}

function Get-IntQuery {
    param($Map, [string]$Key, [int]$Default = 0)
    if (-not $Map.ContainsKey($Key)) { return $Default }
    $n = 0
    if ([int]::TryParse([string]$Map[$Key], [ref]$n)) { return $n }
    return $Default
}

function Get-FlagQuery {
    param($Map, [string]$Key)
    if (-not $Map.ContainsKey($Key)) { return $false }
    $v = ([string]$Map[$Key]).ToLowerInvariant()
    return ($v -eq '1' -or $v -eq 'true' -or $v -eq 'yes')
}

# ---------------------------------------------------------------- check-links

function Invoke-CheckLinks {
    param([string[]]$Urls)

    $clean = @($Urls | Where-Object { $_ -match '^https?://' } | Select-Object -Unique | Select-Object -First 15)
    if ($clean.Count -eq 0) { return [pscustomobject]@{ results = @(); error = 'no urls' } }

    $bodyObj = [pscustomobject]@{ urls = @($clean) }
    $bodyJson = ConvertTo-Json -InputObject $bodyObj -Compress
    $bodyFile = Join-Path $script:tmp 'check-body.json'
    $outFile  = Join-Path $script:tmp 'check-out.json'
    [IO.File]::WriteAllText($bodyFile, $bodyJson, [Text.Encoding]::UTF8)

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $xsrf = Get-XsrfToken
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        $argv = @('-s', '-A', $script:ua, '-b', $script:jar,
            '-H', 'Content-Type: application/json',
            '-H', 'Accept: application/json',
            '-H', 'Origin: https://www.axekin.com',
            '-H', 'Referer: https://www.axekin.com/games',
            '-X', 'POST', '--data-binary', "@$bodyFile",
            '-o', $outFile, '--max-time', '60')
        if ($xsrf) { $argv = @('-s', '-A', $script:ua, '-b', $script:jar,
            '-H', 'Content-Type: application/json',
            '-H', 'Accept: application/json',
            '-H', "X-XSRF-TOKEN: $xsrf",
            '-H', 'Origin: https://www.axekin.com',
            '-H', 'Referer: https://www.axekin.com/games',
            '-X', 'POST', '--data-binary', "@$bodyFile",
            '-o', $outFile, '--max-time', '60') }
        $argv += "$($script:base)/api/games/check-links"
        Invoke-Curl $argv -AllowFail | Out-Null

        $raw = Read-TextFile $outFile
        if ($raw.TrimStart().StartsWith('[') -or $raw.TrimStart().StartsWith('{')) {
            $parsed = $raw | ConvertFrom-Json
            return [pscustomobject]@{ results = @($parsed); error = $null }
        }
        Get-XsrfToken -Refresh | Out-Null
        if ($attempt -eq 0) { Repair-Session -Force }
    }
    return [pscustomobject]@{ results = @(); error = 'availability check failed' }
}

# ---------------------------------------------------------------- server

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "Romsflix catalog demo on http://localhost:$Port/"
Write-Host "  upstream: $($script:base)/games (Anubis session solved on demand)"

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $null
        try {
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 8192, $true)

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { $client.Close(); continue }
            while (($line = $reader.ReadLine()) -ne $null -and $line -ne '') { }

            $parts   = $requestLine.Split(' ')
            $method  = $parts[0]
            $target  = $parts[1]
            $rawPath = ($target -split '\?')[0]
            $query   = if ($target.Contains('?')) { $target.Substring($target.IndexOf('?') + 1) } else { '' }
            $path    = [Uri]::UnescapeDataString($rawPath)
            $q       = Get-QueryMap $query
            $isHead  = $method -eq 'HEAD'

            if ($method -ne 'GET' -and $method -ne 'HEAD') {
                Send-Error $stream 405 'GET/HEAD only' -HeadOnly:$isHead
                continue
            }

            if ($path -eq '/' -or $path -eq '/index.html') {
                $file = Join-Path $root 'index.html'
                if (-not (Test-Path $file)) { Send-Error $stream 404 'index.html missing' -HeadOnly:$isHead; continue }
                $body = [IO.File]::ReadAllBytes($file)
                Send-Response -Stream $stream -Status 200 -ContentType 'text/html; charset=utf-8' -Body $body -HeadOnly:$isHead
                continue
            }

            if ($path -eq '/health') {
                Send-Json $stream ([pscustomobject]@{
                    ok      = $true
                    version = $script:version
                    session = [bool]$script:xsrf
                }) -HeadOnly:$isHead
                continue
            }

            if ($path -eq '/api/bootstrap') {
                $force = $q.ContainsKey('refresh') -and $q['refresh'] -eq '1'
                try {
                    $data = Get-BootstrapData -Force:$force
                    Send-Json $stream $data -Headers @{ 'X-Source' = 'axekin.com (Inertia props)' } -HeadOnly:$isHead
                }
                catch {
                    Send-Error $stream 502 $_.Exception.Message -HeadOnly:$isHead
                }
                continue
            }

            if ($path -eq '/api/games') {
                try {
                    $sortValue = 'newest'
                    if ($q['sort']) { $sortValue = [string]$q['sort'] }
                    $data = Get-GamesData `
                        -Page         (Get-IntQuery $q 'page' 1) `
                        -Platform     ([string]$q['platform']) `
                        -Genre        ([string]$q['genre']) `
                        -Region       ([string]$q['region']) `
                        -Sort         $sortValue `
                        -Search       ([string]$q['search']) `
                        -MinRating    (Get-IntQuery $q 'min_rating' 0) `
                        -MinMetacritic (Get-IntQuery $q 'min_metascore' 0) `
                        -YearFrom     (Get-IntQuery $q 'year_from' 0) `
                        -YearTo       (Get-IntQuery $q 'year_to' 0) `
                        -HasDlc       (Get-FlagQuery $q 'has_dlc') `
                        -HasUpdate    (Get-FlagQuery $q 'has_update') `
                        -Force:($q.ContainsKey('refresh') -and $q['refresh'] -eq '1')
                    Send-Json $stream $data -Headers @{ 'X-Source' = 'axekin.com (Inertia props)' } -HeadOnly:$isHead
                }
                catch {
                    Send-Error $stream 502 $_.Exception.Message -HeadOnly:$isHead
                }
                continue
            }

            if ($path -eq '/api/game') {
                $key = [string]$q['key']
                if (-not $key) { Send-Error $stream 400 'key required' -HeadOnly:$isHead; continue }
                try {
                    $cacheKey = "game|$key"
                    $hit = Get-CacheItem $cacheKey
                    if ($hit) { Send-Json $stream $hit -HeadOnly:$isHead; continue }
                    $page = Invoke-AxekinGame $key
                    if ($page.component -ne 'games/show' -or -not $page.props.game) {
                        Send-Error $stream 404 'game not found' -HeadOnly:$isHead
                        continue
                    }
                    $item = ConvertTo-GameItem $page.props.game
                    try { Save-Images @($item.coverPath, $item.bannerPath) } catch { }
                    Set-CacheItem $cacheKey $item
                    Send-Json $stream $item -HeadOnly:$isHead
                }
                catch {
                    Send-Error $stream 502 $_.Exception.Message -HeadOnly:$isHead
                }
                continue
            }

            if ($path -eq '/api/check-links') {
                try {
                    $urls = @()
                    if ($q.ContainsKey('urls') -and $q['urls']) {
                        $parsed = $q['urls'] | ConvertFrom-Json
                        $urls = @($parsed)
                    }
                    $result = Invoke-CheckLinks -Urls $urls
                    Send-Json $stream $result -HeadOnly:$isHead
                }
                catch {
                    Send-Error $stream 502 $_.Exception.Message -HeadOnly:$isHead
                }
                continue
            }

            if ($path -eq '/img') {
                $p = [string]$q['p']
                if (-not $p) { Send-Error $stream 400 'p required' -HeadOnly:$isHead; continue }
                if ($p -match '^https?://[^/]+(/uploads/.*)$') { $p = $Matches[1] }
                if ($p -notmatch '^/uploads/') { Send-Error $stream 400 'invalid image path' -HeadOnly:$isHead; continue }

                $file = Get-ImageFile $p
                if (-not (Test-ImageBytes $file)) {
                    try { Save-Images @($p) } catch { }
                }
                if (-not (Test-ImageBytes $file)) {
                    Send-Error $stream 404 'image unavailable' -HeadOnly:$isHead
                    continue
                }
                $bytes = [IO.File]::ReadAllBytes($file)
                Send-Response -Stream $stream -Status 200 -ContentType (Get-ImageContentType $file) `
                    -Body $bytes -Headers @{ 'Cache-Control' = 'public, max-age=86400' } -HeadOnly:$isHead
                continue
            }

            if ($path -eq '/favicon.ico') {
                Send-Response -Stream $stream -Status 204 -ContentType 'image/x-icon' -Body ([byte[]]@()) -HeadOnly:$isHead
                continue
            }

            Send-Error $stream 404 'not found' -HeadOnly:$isHead
        }
        catch {
            try { Send-Error $stream 500 $_.Exception.Message } catch { }
        }
        finally {
            if ($stream) { try { $stream.Dispose() } catch { } }
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
}
