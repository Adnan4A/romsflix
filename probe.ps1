$ErrorActionPreference = 'Stop'

$ua    = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36'
$base  = 'https://www.axekin.com'
$dir   = Join-Path $PSScriptRoot 'tmp'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$jar   = Join-Path $dir 'cookies.txt'
$html  = Join-Path $dir 'challenge.html'

Write-Host '1) request page -> challenge'
& curl.exe -s -A $ua -c $jar -o $html --max-time 60 "$base/games?page=1"
$content = Get-Content -Raw $html
Write-Host "   len=$($content.Length) title=$([regex]::Match($content,'<title>([^<]*)').Groups[1].Value)"

$m = [regex]::Match($content, '<script id="anubis_challenge" type="application/json">(.*?)</script>', 'Singleline')
if (-not $m.Success) { Write-Host '   no challenge'; exit 0 }

$ch   = $m.Groups[1].Value | ConvertFrom-Json
$rand = [string]$ch.challenge.randomData
$diff = [int]$ch.challenge.difficulty
$id   = [string]$ch.challenge.id
Write-Host "   id=$id difficulty=$diff"

Write-Host '2) solving'
$sw = [Diagnostics.Stopwatch]::StartNew()
$sha = [Security.Cryptography.SHA256]::Create()
$fullBytes = [Math]::Floor($diff / 2)
$odd = ($diff % 2) -ne 0
$nonce = 0
$hex = $null
while ($true) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($rand + $nonce)
    $hash  = $sha.ComputeHash($bytes)
    $ok = $true
    for ($i = 0; $i -lt $fullBytes; $i++) { if ($hash[$i] -ne 0) { $ok = $false; break } }
    if ($ok -and $odd -and (($hash[$fullBytes] -band 0xF0) -ne 0)) { $ok = $false }
    if ($ok) { $hex = -join ($hash | ForEach-Object { $_.ToString('x2') }); break }
    $nonce++
    if ($nonce -ge 20000000) { throw 'nonce limit' }
}
$sw.Stop()
Write-Host "   nonce=$nonce hash=$($hex.Substring(0,16))... in $([Math]::Round($sw.Elapsed.TotalSeconds,2))s"

Write-Host '3) pass-challenge'
$redir   = [Uri]::EscapeDataString("$base/games?page=1")
$passUrl = "$base/.within.website/x/cmd/anubis/api/pass-challenge?id=$id&response=$hex&nonce=$nonce&redir=$redir&elapsedTime=$([int]$sw.Elapsed.TotalMilliseconds)"
$status = & curl.exe -s -A $ua -b $jar -c $jar -o NUL -w '%{http_code}' --max-time 60 $passUrl
Write-Host "   status=$status"
Write-Host "   cookies: $(Get-Content $jar | Where-Object { $_ -and $_ -notmatch '^#' } | ForEach-Object { ($_ -split "`t")[5] } | Sort-Object -Unique)"

Write-Host '4) fetch inertia json'
$json = & curl.exe -s -A $ua -b $jar -H 'X-Inertia: true' -H 'Accept: application/json' -H 'X-Requested-With: XMLHttpRequest' --max-time 60 "$base/games?page=1"
Write-Host "   len=$($json.Length)"
if ($json.Length -lt 200) { Write-Host "   body: $json"; exit 1 }
$page = $json | ConvertFrom-Json
Write-Host "   component=$($page.component)"
Write-Host "   games: total=$($page.props.games.total) perPage=$($page.props.games.per_page) lastPage=$($page.props.games.last_page) count=$($page.props.games.data.Count)"
Write-Host "   filter keys: $($page.props.filters.PSObject.Properties.Name -join ', ')"
$g = $page.props.games.data[0]
Write-Host "   first: $($g.title) [$($g.titleId)] links=$($g.downloadLinks.Count) platforms=$(($g.platforms | ForEach-Object { $_.slug }) -join ',')"
