# candidates.ps1 - STAGE 2 of the screen. The universe screen ranks spots by best CHUNK COUNT, because that
# is what the record bound is on (-39 blocks <= the sum of the largest <count> cell weights, so beating
# 19,103 needs 78+ chunks at a realistic efficiency). Count alone does not say how much of that ceiling a
# farm reaches: over 18 exact-searched candidates the efficiency ran 86.4% to 96.9%, and the two ran AGAINST
# each other - the 77-chunk spot was the worst at 88.4%, a 74 the best at 96.9%, because packing more slime
# chunks into 226 cells forces them out to the low-weight rim.
#
# So: re-screen the spots that passed the count gate with --y39, which returns count x efficiency directly -
# the number /perimeterinfo reads. 0.2 s per candidate against 30 s of exact search, on the 0.45% that
# passed. Ranked output; the exact search then works down it instead of down the count order.
#
#   powershell -ExecutionPolicy Bypass -File heat\candidates.ps1                # rank only
#   powershell -ExecutionPolicy Bypass -File heat\candidates.ps1 -Search 20     # rank, then exact-search the top 20
param([int]$MinCount = 76, [int]$Search = 0)   # 76 (project owner 2026-10-03): every 19,000+ farm came from a spot screening 78+, and screen 76-77 are the only lower bands that project over 19,000 (docs\HEATMAP.txt "SCREEN GATE"); 74-75 now go to the second pass instead
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$pd = "main\theory\prediction"; $work = "main\work\cand2"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$out = "$pd\candidates.csv"

$done = @{}
foreach ($f in 'main\theory\heat\phase_search.csv', 'main\theory\heat\best_family.csv') {
    if (Test-Path $f) { foreach ($d in (Import-Csv $f)) { $done["$([int]$d.X),$([int]$d.Z)"] = 1 } } }
$src = @("$pd\universe_screened.csv", "$pd\universe_sample.csv", "$pd\floor_sample.csv") | Where-Object { Test-Path $_ }
$cand = @{}
foreach ($f in $src) { foreach ($r in (Import-Csv $f)) {
    if ([int]$r.best -ge $MinCount -and -not $done.ContainsKey("$([int]$r.X),$([int]$r.Z)")) {
        $cand["$([int]$r.X),$([int]$r.Z)"] = $r } } }
$list = @($cand.Values)
if (-not $list.Count) { "no unsearched candidates at $MinCount+ chunks"; return }
"re-screening $($list.Count) candidates ($MinCount+ chunks) by -39 blocks..."

[IO.File]::WriteAllLines((Join-Path $root "$work\in.txt"), [string[]]($list | ForEach-Object { "$([int]$_.X),$([int]$_.Z)" }))
& (Join-Path $root "phase_prepass.exe") --spots "$work\in.txt" --out "$work\out.csv" --probe 8 --exhaust 64 --top-pct 0.25 --y39 | Out-Null
if (-not (Test-Path "$work\out.csv")) { "the -39 re-screen wrote nothing"; return }

$b39 = @{}; foreach ($r in (Import-Csv "$work\out.csv")) { $b39["$([int]$r.X),$([int]$r.Z)"] = [int]$r.best }
$rows = foreach ($c in $list) { $k = "$([int]$c.X),$([int]$c.Z)"; $n = [int]$c.best; $p = [int]$b39[$k]
    [pscustomobject]@{ X = [int]$c.X; Z = [int]$c.Z; heat = $c.heat; chunks = $n; blocks39 = $p
        ceiling = 256 * $n; efficiency = $(if ($n) { [math]::Round(100 * $p / (256 * $n), 1) } else { 0 }) } }
$rows = @($rows | Sort-Object blocks39 -Descending)
$rows | Export-Csv $out -NoTypeInformation
"ranked -> $out"
# Record range, from 76 searched candidates (docs\PREDICTION.txt 13h): final farm = 4092 + 0.787 x screen39, residual sd
# 362 (90th pct, max +1,148). A READING of the batch, never a skip - every candidate is searched.
$live = @($rows | Where-Object { $_.blocks39 -ge 18474 }).Count
$long = @($rows | Where-Object { $_.blocks39 -ge 17613 -and $_.blocks39 -lt 18474 }).Count
"record range: $live at 18,474+ (beats 19,103 at a 90th-pct residual), $long more at 17,613+ (only at the largest residual seen), $($rows.Count - $live - $long) below"
$rows | Select-Object -First 10 | ForEach-Object {
    "  {0,6} blocks  {1} chunks  {2}% of ceiling  heat {3,-7} ({4},{5})" -f $_.blocks39, $_.chunks, $_.efficiency, $_.heat, $_.X, $_.Z }

if ($Search -gt 0) {
    $pick = @($rows | Select-Object -First $Search)
    $pick | ForEach-Object { [pscustomobject]@{ X = $_.X; Z = $_.Z; Line = ''; Heat40 = $_.heat } } | Export-Csv "$work\picks.csv" -NoTypeInformation
    "exact-searching the top $($pick.Count) by -39 blocks ({0}..{1})" -f $pick[0].blocks39, $pick[-1].blocks39
    & (Join-Path $root "heat\phase_spots.ps1") -SpotFile "$work\picks.csv" -Spots $pick.Count -Work main\work\cand2run |
        Where-Object { $_ -match '^\[|BIG' }
}
