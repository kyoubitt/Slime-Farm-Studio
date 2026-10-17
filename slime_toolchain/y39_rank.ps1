# y39_rank.ps1 - ONE-SHOT: rank EVERY farm in main\records\over66.csv by the number /perimeterinfo reads at
# y -39 (feet at -39 over a -64 floor, dy 24, AFK free to move +-48; a full floor is 49,669). Writes
# main\records\y39_all.csv, sorted best first. ~45 s for 2,900 farms - cheap enough to re-run after any batch.
#
# Why this exists: the search files and ranks farms by cq (the dy-0 number), but the record is a -39 number,
# and the two disagree. Measured 2026-09-21 over all 2,902 filed farms (docs\PREDICTION.txt 13c): 11 of the top 50
# by -39 are NOT in the top 50 by cq, and at cq 69.x the -39 range is 17,289-18,598 - a 1,309-block spread
# against ~265 blocks per cq point. The side folder main\records\over70_y-39\ only ever covered the 401 farms
# whose record image is still on disk; this covers all of them, and as a CSV it can be joined and sorted.
#
# An ESTIMATE, never a claim: in-game /perimeterinfo wins, and measured farms are flagged from
# main\records\measured_in_game.csv so the two are never confused.
#
#   powershell -ExecutionPolicy Bypass -File y39_rank.ps1
#   powershell -ExecutionPolicy Bypass -File y39_rank.ps1 -Top 25      # also print the top 25
param([int]$Window = 48, [int]$Top = 15)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$rec = "main\records"; $work = "main\work\y39rank"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$farms = @(Import-Csv "$rec\over66.csv" -ErrorAction SilentlyContinue | Where-Object { $_.X })   # missing on a fresh copy: the notice below says so
if (-not $farms.Count) { "y39_rank.ps1: no farms in main\records\over66.csv. This ranks farms YOUR hunt has filed; a fresh copy has none. Run record_cycle.ps1 -PhaseSearch -BestFamilySpots main\best_spots.csv first - every 66+ find is logged to over66.csv automatically."; exit 1 }
$in = "$work\in.csv"; $out = "$work\out.csv"
# CACHE (2026-10-03): afk_rescan is a pure function of (seed, x, z, --dy 24, --window), so a farm scored
# once never needs scoring again - and this script runs over the WHOLE archive twice per section, which was
# 67-114 s a call and growing with every farm filed. Keyed seed|x|z; the window and the exe's own timestamp
# are in the cache file name, so changing either starts a fresh cache instead of serving stale numbers.
$exe = Join-Path $root "afk_rescan.exe"
$stamp = (Get-Item -LiteralPath $exe).LastWriteTime.ToString('yyyyMMddHHmmss')
$cacheFile = "$work\cache_w${Window}_$stamp.csv"
# A row is only trusted if every field afk_rescan writes is present: a torn write (the cache is replaced
# whole) would otherwise leave a key with a $null blocks_dy_best, which casts to 0 and would pin that farm
# at the BOTTOM of the ranking forever - the pre-cache code rescanned everything, so it self-corrected.
$cache = @{}
if (Test-Path $cacheFile) {
    $drop = 0
    foreach ($c in (Import-Csv $cacheFile)) {
        if ($c.blocks_dy_best -match '^\d+$' -and $c.best_x -match '^-?\d+$' -and $c.best_z -match '^-?\d+$' -and
            $c.shift -match '^-?[\d.]+$' -and $c.blocks_y0 -match '^\d+$' -and $c.blocks_dy_same_afk -match '^\d+$') {
            $cache["$($c.seed)|$($c.x)|$($c.z)"] = $c } else { $drop++ } }
    if ($drop) { "cache: $drop incomplete row(s) ignored, they will be re-scanned" } }
$need = @($farms | Where-Object { -not $cache.ContainsKey("$($_.Seed)|$($_.X)|$($_.Z)") })
if ($need.Count) {
    @("seed,x,z,cq") + @($need | ForEach-Object { "{0},{1},{2},{3}" -f $_.Seed, $_.X, $_.Z, $_.CQ }) |
        Set-Content $in -Encoding ascii
    "ranking $($need.Count) new farm(s) at y -39 (window $Window); $($cache.Count) from cache"
    Remove-Item $out -ErrorAction SilentlyContinue      # never read a previous run's output if this one dies
    & $exe --in $in --out $out --dy 24 --window $Window | Out-Null
    if (-not (Test-Path $out)) { "afk_rescan wrote nothing"; exit 1 }
    foreach ($c in (Import-Csv $out)) { $cache["$($c.seed)|$($c.x)|$($c.z)"] = $c }
    $miss = @($need | Where-Object { -not $cache.ContainsKey("$($_.Seed)|$($_.X)|$($_.Z)") })
    if ($miss.Count) {
        "afk_rescan returned nothing for $($miss.Count) of $($need.Count) farm(s), first: $($miss[0].Seed)"
        "y39_all.csv left unchanged"; exit 1 }
    # whole-file replace, so write to a temp and rename: a half-written cache would be trusted next run
    $cache.Values | Export-Csv "$cacheFile.tmp" -NoTypeInformation
    Move-Item "$cacheFile.tmp" $cacheFile -Force
} else { "all $($farms.Count) farms already scored at y -39 (window $Window)" }
$measured = @{}
if (Test-Path "$rec\measured_in_game.csv") {
    foreach ($m in (Import-Csv "$rec\measured_in_game.csv")) { $measured[$m.seed] = $m.ingame } }
# rows in over66.csv order - the same order afk_rescan echoed its input in, so the sort below sees the
# identical sequence it always did and ties keep the order they had
$rows = @(foreach ($f in $farms) {
    $r = $cache["$($f.Seed)|$($f.X)|$($f.Z)"]
    if (-not $r) { continue }
    [pscustomobject]@{ blocks39 = [int]$r.blocks_dy_best; cq = $f.CQ; seed = $f.Seed
        best_x = $r.best_x; best_z = $r.best_z; shift = $r.shift
        ingame = $(if ($measured.ContainsKey($f.Seed)) { $measured[$f.Seed] } else { "" })
        chunks = $f.Chunks; heat = $f.Heat40; spot_x = $f.SpotX; spot_z = $f.SpotZ } })
if ($rows.Count -ne $farms.Count) {
    # y39_all.csv is the only -39 ranking of the archive and is replaced in place, so never write a short one
    "only $($rows.Count) of $($farms.Count) farms have a y -39 score - y39_all.csv left unchanged"; exit 1 }
$rows = @($rows | Sort-Object blocks39 -Descending)
$i = 0
$rows = @(foreach ($r in $rows) { $i++
    [pscustomobject]@{ rank = $i; blocks39 = $r.blocks39; ingame = $r.ingame; cq = $r.cq; seed = $r.seed
        best_x = $r.best_x; best_z = $r.best_z; shift = $r.shift; chunks = $r.chunks; heat = $r.heat
        spot_x = $r.spot_x; spot_z = $r.spot_z } })
$rows | Export-Csv "$rec\y39_all.csv" -NoTypeInformation
"ranked $($rows.Count) farms -> $rec\y39_all.csv"
if ($Top -gt 0) {
    $rows | Select-Object -First $Top | ForEach-Object {
        "  {0,3}. {1,6}{2}  cq {3,-6} {4}" -f $_.rank, $_.blocks39, $(if ($_.ingame) { " (in game $($_.ingame))" } else { "" }), $_.cq, $_.seed } }
