# predict_cycle.ps1 - the PREDICTION SEARCH. Separate from record_cycle -PhaseSearch (the heat-list WR search), which it
# does not change. Each cycle:
#   1. CHUNK: -Chunk fresh spots from the whole-world survey (main\theory\heat\spot_measured.csv, heat >= -MinHeat): half the
#      chosen by the COMBINED PRIOR (heat z-score minus geo_rank's H-clustering z-score: corr +0.234 with the screen's
#      best count on 11,920 unselected spots, against +0.144 heat alone and -0.150 geometry alone - the prediction study 9b),
#      half random from the rest as a control band - rich spots hide at low heat too (the 70.80 came from heat 25.9).
#      "Fresh" = the search's same-farm rule (+-4 chunks X, +-2 rows Z) against every searched AND every screened spot.
#   2. STAGE 1: phase_prepass PROBE screen - 8 classes on each family of the top 0.25%, then ALL 32,768 classes of the
#      best 64 of them (~0.24 s/spot).  3. STAGE 2: the top -Stage2Frac again, wider (top 1%, best 128 exhausted).
#      The probe screen finds the spot's true exact best (within 2) at 84% / 94%, against 34% for the old 512-random
#      sample at the same price (180 spots of known exact best, 2026-09-20; see the prediction study (not shipped), section 8).
#      Both stages score in -39 BLOCKS (--y39: the raised-AFK weighting, 0 <= a^2 + b^2 <= 15808, no inner circle -
#      a full floor reads 49,669, exactly the in-game number). Against the true -39 count of 303 filed farms, that
#      objective correlates +0.74, against +0.37 for cq blocks and +0.21 for the chunk count the search used before
#      (the prediction study, section 10) - the screen now ranks spots by what /perimeterinfo will read.
#   4. SCORE = stage-2 best / 256 + log2(1 + stage-2 pairs reaching 68) - the best of 6 scores on 80 spots with known
#      exact results (Spearman 0.73 with the exact best cq over 30 spread spots, 0.56 inside the top 50).
#   5. EXACT: the top -Exact spots through the normal exact search (heat\phase_spots.ps1) - logged in phase_search.csv, farms
#      filed as always. The exact search per spot is unchanged; unpicked spots stay available.
# Why: its first test picked 50 of 2,000 spots holding 67+ at 30% (heat list 7%), 68+ 14% (1%), four farms of 69.9+.
# Logs: main\predict_cycles.txt (one line per cycle), main\theory\prediction\screened.csv (every screened spot; its best512 / best2048
#       columns keep their names but hold the stage-1 / stage-2 PROBE results from 2026-09-20 on).
# Stop: main\STOP_WR (checked between stages) or stop_all.ps1. Resumable: unsearched picks of a stopped cycle go first.
param([int]$Repeat = 1, [int]$Chunk = 2000, [double]$Stage2Frac = 0.10, [int]$Exact = 50, [double]$MinHeat = 20)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$pd = "main\theory\prediction"; $work = "main\work\predict"; New-Item -ItemType Directory -Force -Path $pd, $work | Out-Null
$screenedCsv = "$pd\screened.csv"; $cycles = "main\predict_cycles.txt"; $uni = "$pd\universe_h$([int]$MinHeat).csv"
function Stopped { Test-Path "main\STOP_WR" }

if (-not (Test-Path $uni) -and -not (Test-Path "$root\main\theory\heat\spot_measured.csv")) {
    Write-Host "predict_cycle.ps1 needs main\theory\heat\spot_measured.csv - the whole-world heat survey (183,536 spots). It is not part of this copy, so this mode is unavailable. Use: record_cycle.ps1 -PhaseSearch -BestFamilySpots main\best_spots.csv" -ForegroundColor Yellow
    exit 1 }
# the universe, cached once: every surveyed spot at heat >= MinHeat, hottest first
if (-not (Test-Path $uni)) {
    $L = New-Object System.Collections.Generic.List[object]; $k = 0
    foreach ($ln in [IO.File]::ReadLines((Join-Path $root "main\theory\heat\spot_measured.csv"))) { $k++; if ($k -eq 1) { continue }
        $f = $ln.Split(','); $hv = [double]$f[2]; if ($hv -ge $MinHeat) { $L.Add([pscustomobject]@{ cx = [int]$f[0]; cz = [int]$f[1]; heat = $hv }) } }
    $L | Sort-Object heat -Descending | Export-Csv $uni -NoTypeInformation
    "universe: $($L.Count) spots at heat >= $MinHeat cached in $uni" }
$U = @(Import-Csv $uni | ForEach-Object { [pscustomobject]@{ cx = [int]$_.cx; cz = [int]$_.cz; heat = [double]$_.heat } })

# the GEOMETRY PRIOR, cached once (geo_rank, ~40 s for the whole universe): pairs of window chunks whose H values are
# within 512, the minimum over the 15 grid positions - pure spot geometry, no family and no class. Corr -0.150 with
# the screen's best on 11,920 UNSELECTED spots (the -0.288 measured on the 1,724 exact-searched spots was selection
# bias - those spots were themselves picked by heat and the old screen). Nearly independent of heat, so both are used.
$geoCsv = "$pd\universe_geo.csv"
if (-not (Test-Path $geoCsv)) {
    [IO.File]::WriteAllLines((Join-Path $root "$work\geo_in.txt"), [string[]]($U | ForEach-Object { "{0},{1}" -f ($_.cx * 16), ($_.cz * 16) }))
    & (Join-Path $root "geo_rank.exe") --spots "$work\geo_in.txt" --out $geoCsv --threads 8 | Out-Null }
$geo = @{}; foreach ($ln in [IO.File]::ReadLines((Join-Path $root "$geoCsv"))) { $f = $ln.Split(','); if ($f[2] -match '^\d+$') { $geo["$($f[0]),$($f[1])"] = [int]$f[2] } }
# band A = the COMBINED prior, heat z-score minus geometry z-score. On 11,920 unselected spots it correlates +0.234
# with the screen's best count, against +0.144 for heat alone and -0.150 for geometry alone (they are near
# independent). Honest limit: the top decile of it holds a 70+ at 18.0% against a 12.9% base rate, but a 74+ at only
# 0.17% against 0.14% - a prior moves the middle of the distribution, not the tail. The screen is what finds records.
$hv = @($U | ForEach-Object { $_.heat }); $hm = ($hv | Measure-Object -Average).Average
$hs = [math]::Sqrt((($hv | ForEach-Object { ($_ - $hm) * ($_ - $hm) }) | Measure-Object -Sum).Sum / $hv.Count)
$gv = @($U | ForEach-Object { $g = $geo["$($_.cx * 16),$($_.cz * 16)"]; if ($null -eq $g) { 0 } else { $g } })
$gm = ($gv | Measure-Object -Average).Average
$gs = [math]::Sqrt((($gv | ForEach-Object { ($_ - $gm) * ($_ - $gm) }) | Measure-Object -Sum).Sum / $gv.Count)
if ($hs -le 0) { $hs = 1 }; if ($gs -le 0) { $gs = 1 }
$UG = @($U | Sort-Object -Descending @{ e = { $g = $geo["$($_.cx * 16),$($_.cz * 16)"]; if ($null -eq $g) { $g = $gm }; (($_.heat - $hm) / $hs) - (($g - $gm) / $gs) } })

for ($cyc = 1; $cyc -le $Repeat; $cyc++) {
    if (Stopped) { "STOP_WR present - stopping"; break }
    $t0 = Get-Date
    $num = 1 + @(Get-Content $cycles -ErrorAction SilentlyContinue | Where-Object { $_ -match '^#\d+ ' }).Count
    # --- taken rows: every searched spot and every screened spot (same-farm rule) ---
    $rows = @{}
    function Add-Taken($cx, $row) { if (-not $rows.ContainsKey($row)) { $rows[$row] = New-Object System.Collections.Generic.List[int] }; $rows[$row].Add($cx) }
    function Near($cx, $row) { for ($dr = -2; $dr -le 2; $dr++) { $l = $rows[$row + $dr]; if ($l) { foreach ($hx in $l) { if ([math]::Abs($hx - $cx) -le 4) { return $true } } } }; return $false }
    $searched = @{}
    foreach ($f in 'main\theory\heat\phase_search.csv', 'main\theory\heat\best_family.csv') { if (Test-Path $f) { foreach ($d in (Import-Csv $f)) {
        Add-Taken ([int][math]::Floor([double]$d.X / 16)) ([int][math]::Floor([double]$d.Z / 16)); $searched["$($d.X),$($d.Z)"] = 1 } } }
    $prev = @(); if (Test-Path $screenedCsv) { $prev = @(Import-Csv $screenedCsv) }
    foreach ($d in $prev) { Add-Taken ([int][math]::Floor([double]$d.X / 16)) ([int][math]::Floor([double]$d.Z / 16)) }
    # --- resume: picks of an earlier cycle that were never exact-searched go first ---
    $pending = @($prev | Where-Object { $_.picked -eq '1' -and -not $searched.ContainsKey("$($_.X),$($_.Z)") })
    if ($pending.Count) {
        "resuming: $($pending.Count) unsearched picks from an earlier cycle"
        $pending | ForEach-Object { [pscustomobject]@{ X = $_.X; Z = $_.Z; Line = $_.line; Heat40 = $_.heat } } | Export-Csv "$work\picks.csv" -NoTypeInformation
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "heat\phase_spots.ps1") -SpotFile "$work\picks.csv" -Spots $pending.Count | Where-Object { $_ -match '^\[' }
        continue }
    # --- 1. chunk: half by the geometry prior (band 'prior'), half random fresh (the control band) ---
    $half = [int]($Chunk / 2); $pickA = New-Object System.Collections.Generic.List[object]; $pickB = New-Object System.Collections.Generic.List[object]
    $ia = 0
    for (; $ia -lt $UG.Count -and $pickA.Count -lt $half; $ia++) { $s = $UG[$ia]; if (Near $s.cx $s.cz) { continue }; $pickA.Add($s); Add-Taken $s.cx $s.cz }
    $rng = New-Object System.Random ([int]((Get-Date).Ticks % 1000000007)); $tries = 0
    while ($pickB.Count -lt ($Chunk - $half) -and $tries -lt 50 * $Chunk) { $tries++
        $s = $U[$rng.Next(0, $U.Count)]; if (Near $s.cx $s.cz) { continue }; $pickB.Add($s); Add-Taken $s.cx $s.cz }
    $chunkRows = @($pickA | ForEach-Object { [pscustomobject]@{ cx = $_.cx; cz = $_.cz; heat = $_.heat; band = 'prior' } }) + @($pickB | ForEach-Object { [pscustomobject]@{ cx = $_.cx; cz = $_.cz; heat = $_.heat; band = 'random' } })
    if (-not $chunkRows.Count) { "no fresh spots left at heat >= $MinHeat"; break }
    [IO.File]::WriteAllLines((Join-Path $root "$work\chunk.txt"), [string[]]($chunkRows | ForEach-Object { "{0},{1}" -f ($_.cx * 16), ($_.cz * 16) }))
    "=== PREDICT #$num ($cyc of $Repeat): $($pickA.Count) by the combined prior (heat {0:F1}..{1:F1}) + $($pickB.Count) random fresh ===" -f $pickA[0].heat, $pickA[$pickA.Count - 1].heat
    # --- 2. stage 1 ---
    & (Join-Path $root "phase_prepass.exe") --spots "$work\chunk.txt" --out "$work\stage1.csv" --probe 8 --exhaust 64 --top-pct 0.25 --y39 | Out-Null
    $s1 = @{}; foreach ($r in (Import-Csv "$work\stage1.csv")) { $s1["$($r.X),$($r.Z)"] = $r }
    "  stage 1: $($s1.Count) spots screened (probe, top 0.25% x 64 exhausted)  [{0:F0} min]" -f ((Get-Date) - $t0).TotalMinutes
    # --- 3. stage 2 on the top fraction ---
    $n2 = [math]::Max($Exact, [int][math]::Ceiling($Stage2Frac * $s1.Count))
    $top1 = @($s1.Values | Sort-Object @{ e = { [int]$_.best }; Descending = $true }, @{ e = { [int]$_.pairs68 }; Descending = $true } | Select-Object -First $n2)
    [IO.File]::WriteAllLines((Join-Path $root "$work\stage2_in.txt"), [string[]]($top1 | ForEach-Object { "$($_.X),$($_.Z)" }))
    # stopped between the stages: record nothing - an unscored chunk marked "screened" would never be picked (found 2026-09-13)
    if (Stopped) { "STOP_WR present - this chunk is not recorded; it will be screened again"; break }
    $s2 = @{}
    & (Join-Path $root "phase_prepass.exe") --spots "$work\stage2_in.txt" --out "$work\stage2.csv" --probe 8 --exhaust 128 --top-pct 1 --y39 | Out-Null
    foreach ($r in (Import-Csv "$work\stage2.csv")) { $s2["$($r.X),$($r.Z)"] = $r }
    if ($s2.Count -lt [math]::Min($Exact, $top1.Count)) { "stage 2 incomplete ($($s2.Count) of $($top1.Count)) - chunk not recorded"; break }
    "  stage 2: $($s2.Count) spots (probe, top 1% x 128 exhausted)  [{0:F0} min]" -f ((Get-Date) - $t0).TotalMinutes
    # --- 4. score and pick ---
    $scored = foreach ($c in $chunkRows) { $k = "{0},{1}" -f ($c.cx * 16), ($c.cz * 16); $a1 = $s1[$k]; $a2 = $s2[$k]
        $sc = $(if ($a2) { [double]$a2.best / 256 + [math]::Log(1 + [double]$a2.pairs68, 2) } else { -1 })      # best is now -39 BLOCKS: /256 keeps the old balance
        [pscustomobject]@{ X = $c.cx * 16; Z = $c.cz * 16; heat = $c.heat; line = [int][math]::Round(($c.cz - 48.5) / 96.875); band = $c.band; cycle = $num
            best512 = $(if ($a1) { $a1.best } else { '' }); pairs68_512 = $(if ($a1) { $a1.pairs68 } else { '' }); fam66_512 = $(if ($a1) { $a1.families66 } else { '' })
            best2048 = $(if ($a2) { $a2.best } else { '' }); pairs68_2048 = $(if ($a2) { $a2.pairs68 } else { '' }); fam66_2048 = $(if ($a2) { $a2.families66 } else { '' })
            score = [math]::Round($sc, 3); picked = '0' } }
    $picks = @($scored | Where-Object { $_.score -ge 0 } | Sort-Object score -Descending | Select-Object -First $Exact)
    foreach ($p in $picks) { $p.picked = '1' }
    $scored | Export-Csv $screenedCsv -NoTypeInformation -Append        # every screened spot, once (never re-screened)
    if (Stopped) { "STOP_WR present - screened results saved; the picks are searched first next time"; break }
    # --- 5. exact search of the picks ---
    $picks | ForEach-Object { [pscustomobject]@{ X = $_.X; Z = $_.Z; Line = $_.line; Heat40 = $_.heat } } | Export-Csv "$work\picks.csv" -NoTypeInformation
    "  exact search of the top $($picks.Count) (score {0:F1}..{1:F1}; {2} hot, {3} random)" -f $picks[0].score, $picks[-1].score, @($picks | Where-Object { $_.band -eq 'hot' }).Count, @($picks | Where-Object { $_.band -eq 'random' }).Count
    $o66Before = @(Import-Csv main\records\over66.csv).Count
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "heat\phase_spots.ps1") -SpotFile "$work\picks.csv" -Spots $picks.Count | Where-Object { $_ -match '^\[|BIG' }
    # --- cycle line ---
    $res = @{}; foreach ($r in (Import-Csv main\theory\heat\phase_search.csv)) { $res["$($r.X),$($r.Z)"] = $r }
    $got = @($picks | ForEach-Object { $res["$($_.X),$($_.Z)"] } | Where-Object { $_ -and $_.SpotBest })
    $bb = @($got | ForEach-Object { [double]$_.SpotBest }); $top = $got | Sort-Object { [double]$_.SpotBest } -Descending | Select-Object -First 1
    $line = "#{0}  {1}  predict  {2} screened, {3} at stage 2, {4} exact: best {5} cq {6}  67+ {7}  68+ {8}  69+ {9}  new 66+: {10}  {11:F0} min" -f $num, (Get-Date -Format 'yyyy-MM-dd HH:mm'), $chunkRows.Count, $s2.Count, $got.Count,
        $(if ($top) { $top.SpotBest } else { '-' }), $(if ($top) { $top.BestAt } else { '' }), @($bb | Where-Object { $_ -ge 67 }).Count, @($bb | Where-Object { $_ -ge 68 }).Count, @($bb | Where-Object { $_ -ge 69 }).Count,
        (@(Import-Csv main\records\over66.csv).Count - $o66Before), ((Get-Date) - $t0).TotalMinutes
    Add-Content $cycles $line; $line
}
