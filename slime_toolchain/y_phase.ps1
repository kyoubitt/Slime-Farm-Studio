# y_phase.ps1 - THE Y PHASE: every standing height, on a few good farms only.
#
# Everything else scores a farm at ONE height (slime_refine: level with the spawn floor; afk_rescan /
# the -39 hints: feet at y -39). Standing height changes which columns count - both spheres are 3D:
#     vanilla spawn:  24^2 < a^2 + b^2 + dy^2 <= 128^2      dy = feet y - spawn y (-63 over a -64 floor)
# Low (dy 0) keeps the full 128 outer circle but loses a 24-block hole in the middle; at -39 (dy 24)
# the hole is gone (slimes spawn right under you) and the outer circle is 125.7. Above -39 the count
# can only shrink (a subset of dy 24's), so the useful range is feet y -63 .. -39, and which one wins
# depends on the farm: measured on the two old records, the 66.04 gains +207 at -39 (17,112 - its
# in-game number exactly) while the 66.21 LOSES 386 there and is best standing on the floor.
#
# So this does not assume an answer: it measures each height (afk_rescan --dy-from/--dy-to, best AFK
# point within +-Window blocks at every height, vanilla rule and the /perimeterinfo reading) and
# prints how much moving off -39 actually gains.
#
# WHICH FARMS. Normal cq is scored standing on the floor, and that ranks farms differently from -39
# (the 70.64 beats the 69.39 on the floor; the 69.39 wins at -39, 18,597 vs 18,313). So every new
# farm at or above -MinCQ first gets ONE quick check at -39 (afk_rescan --dy 24, best AFK point
# within +-Window) and is ranked by the better of that and its floor-level count - the better END,
# so a farm that is best on the floor (the 66.21) is not dropped. Only the top -Top get the sweep.
#
# DELIBERATELY SMALL. At most -PreMax (200) quick checks + -Top (5) farms x 25 heights = 125 sweep
# runs, a couple of seconds. Hard caps: -PreMax <= 500, -Top <= 20 and <= 500 sweep runs per call.
# Farms already in main\y_phase.csv are skipped, so a farm is only ever swept once - the anchor's
# recurring 66.04 is not redone every cycle. record_cycle.ps1 calls this once per cycle (-YPhaseTop 0 there turns it off); it never
# changes the hunt, the ranking or any record - it only adds main\y_phase.csv.
#
#   powershell -File y_phase.ps1 -In main\pipeline.csv                  (any CSV with CQ,Seed,X,Z)
#   powershell -File y_phase.ps1 -In main\records\over66.csv -Top 10 -MinCQ 69
param(
    [Parameter(Mandatory = $true)][string]$In,
    [int]$Skip = 0,                 # ignore the first N rows of -In (e.g. rows from before this batch)
    [int]$Top = 5,
    [int]$PreMax = 200,             # at most this many new farms get the one quick -39 check
    [double]$MinCQ = 66.0,
    [int]$DyFrom = 0,               # feet y = SpawnY + dy
    [int]$DyTo = 24,
    [int]$Window = 48,              # best AFK point searched within +-Window blocks at each height
    [int]$SpawnY = -63,             # spawn level: one above the -64 floor (0 floor -> 1)
    [string]$Label = ""
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

$exe = Join-Path $root "afk_rescan.exe"
if (-not (Test-Path $exe)) { Write-Host "y phase: afk_rescan.exe missing - run build first" -ForegroundColor Yellow; exit 0 }
if (-not (Test-Path $In)) { exit 0 }
$levels = $DyTo - $DyFrom + 1
if ($Top -gt 20) { $Top = 20 }
if ($Top * $levels -gt 500) { $Top = [math]::Max(1, [math]::Floor(500 / $levels)) }   # never more than 500 sweep runs
if ($PreMax -gt 500) { $PreMax = 500 }
if ($PreMax -lt $Top) { $PreMax = $Top }

$out = Join-Path $root "main\y_phase.csv"
$done = @{}
if (Test-Path $out) { foreach ($r in (Import-Csv $out)) { $done["$($r.Seed),$($r.X),$($r.Z)"] = 1 } }

# candidates: this batch's farms, best first, one row per (seed, AFK point), not already swept
$seen = @{}
$cands = @(Import-Csv $In | Select-Object -Skip $Skip |
    Where-Object { $_.Seed -match '^-?\d+$' -and $_.X -match '^-?\d+$' -and $_.Z -match '^-?\d+$' -and [double]$_.CQ -ge $MinCQ } |
    Sort-Object { [double]$_.CQ } -Descending |
    Where-Object { $k = "$($_.Seed),$($_.X),$($_.Z)"; if ($seen.ContainsKey($k) -or $done.ContainsKey($k)) { $false } else { $seen[$k] = 1; $true } } |
    Select-Object -First $PreMax)
if ($cands.Count -eq 0) { exit 0 }

$work = Join-Path $root "main\work"; New-Item -ItemType Directory -Force -Path $work | Out-Null

# pick the farms to sweep: one quick -39 check each, ranked by the better end (-39 or floor)
$t0 = Get-Date; $preRuns = 0
if ($cands.Count -gt $Top) {
    $pin = Join-Path $work "y_phase_pre_in.csv"; $pout = Join-Path $work "y_phase_pre_out.csv"
    Set-Content -Path $pin -Encoding ascii -Value (@("seed,x,z") + @($cands | ForEach-Object { "$($_.Seed),$($_.X),$($_.Z)" }))
    Remove-Item $pout -ErrorAction SilentlyContinue
    & $exe --in $pin --out $pout --dy 24 --window $Window | Out-Null
    $endBest = @{}
    if (Test-Path $pout) {
        foreach ($r in (Import-Csv $pout)) { $endBest["$($r.seed),$($r.x),$($r.z)"] = [math]::Max([int]$r.vanilla_dy_best, [int]$r.blocks_y0) } }
    Remove-Item $pin, $pout -ErrorAction SilentlyContinue
    $preRuns = $cands.Count
    $farms = @($cands | Sort-Object { $k = "$($_.Seed),$($_.X),$($_.Z)"; if ($endBest.ContainsKey($k)) { $endBest[$k] } else { 0 } } -Descending |
        Select-Object -First $Top)
    Write-Host ""
    Write-Host ("y phase: picked {0} of {1} new farms by their best end (-39 or floor): {1} quick checks + {0} x {2} sweep runs" -f `
        $farms.Count, $cands.Count, $levels) -ForegroundColor DarkGray
} else {
    $farms = $cands
}
$fin = Join-Path $work "y_phase_in.csv"; $fout = Join-Path $work "y_phase_out.csv"
Set-Content -Path $fin -Encoding ascii -Value (@("seed,x,z,cq") + @($farms | ForEach-Object { "$($_.Seed),$($_.X),$($_.Z),$($_.CQ)" }))
Remove-Item $fout -ErrorAction SilentlyContinue
& $exe --in $fin --out $fout --dy-from $DyFrom --dy-to $DyTo --window $Window --spawn-y $SpawnY | Out-Null
if (-not (Test-Path $fout)) { Write-Host "y phase: afk_rescan produced nothing" -ForegroundColor Yellow; exit 0 }
$rows = @(Import-Csv $fout)
$secs = ((Get-Date) - $t0).TotalSeconds

# in-game numbers, when this farm (or a seed with the identical slime map, within 64 blocks) has been measured
$meas = @(); $mf = Join-Path $root "main\records\measured_in_game.csv"
if (Test-Path $mf) { $meas = @(Import-Csv $mf) }

Write-Host ""
Write-Host ("=== Y PHASE: {0} farm(s) x {1} heights (feet y {2}..{3}), best AFK point within +-{4} ===" -f `
    $farms.Count, $levels, ($SpawnY + $DyFrom), ($SpawnY + $DyTo), $Window) -ForegroundColor Cyan
Write-Host "      cq  seed                   floor  -39 vanilla  -39 perimeterinfo  best feet y  vanilla  vs -39  vs floor  in game  best AFK x,z"
if (-not (Test-Path $out)) {
    Set-Content -Path $out -Encoding ascii -Value "Date,Label,CQ,Seed,X,Z,BlocksY0,Vanilla39,Carpet39,BestFeetY,BestVanilla,BestCarpet,BestX,BestZ,GainVs39,GainVsY0"
}
$gains = @()
foreach ($f in $farms) {
    $mine = @($rows | Where-Object { $_.seed -eq $f.Seed -and $_.x -eq $f.X -and $_.z -eq $f.Z })
    if ($mine.Count -eq 0) { continue }
    $y0  = [int]$mine[0].blocks_y0
    $at39 = $mine | Where-Object { [int]$_.dy -eq 24 } | Select-Object -First 1   # "-39" = 24 above the spawn level
    $best = $mine | Sort-Object { [int]$_.blocks_vanilla }, { [int]$_.blocks_carpet } -Descending | Select-Object -First 1
    $v39 = if ($at39) { [int]$at39.blocks_vanilla } else { $null }
    $c39 = if ($at39) { [int]$at39.blocks_carpet } else { $null }
    $g39 = if ($at39) { [int]$best.blocks_vanilla - $v39 } else { $null }
    $gY0 = [int]$best.blocks_vanilla - $y0
    if ($null -ne $g39) { $gains += $g39 }
    $ig = ""
    # same slime map only (equal low 48 bits) at the same spot - a different seed nearby is a different layout
    $m = $meas | Where-Object { $_.seed -match '^-?\d+$' -and (([long]$_.seed -band 0xFFFFFFFFFFFF) -eq ([long]$f.Seed -band 0xFFFFFFFFFFFF)) -and
        [math]::Abs([long]$_.x - [long]$f.X) -le 64 -and [math]::Abs([long]$_.z - [long]$f.Z) -le 64 } | Select-Object -First 1
    if ($m) { $ig = [string]$m.ingame }
    $col = if ($g39 -gt 0) { "Yellow" } else { "Gray" }
    Write-Host ("  {0,6}  {1,-20}  {2,6}  {3,11}  {4,17}  {5,11}  {6,7}  {7,6}  {8,8}  {9,7}  {10}" -f `
        $f.CQ, $f.Seed, $y0, $v39, $c39, $best.feet_y, $best.blocks_vanilla,
        $(if ($null -ne $g39) { "{0:+#;-#;0}" -f $g39 } else { "" }), ("{0:+#;-#;0}" -f $gY0), $ig,
        ("{0},{1}" -f $best.best_x, $best.best_z)) -ForegroundColor $col
    Add-Content -Path $out -Encoding ascii -Value ("{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15}" -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm'), ($Label -replace ',', ';'), $f.CQ, $f.Seed, $f.X, $f.Z, $y0, $v39, $c39,
        $best.feet_y, $best.blocks_vanilla, $best.blocks_carpet, $best.best_x, $best.best_z, $g39, $gY0)
}
if ($gains.Count) {
    $mx = ($gains | Measure-Object -Maximum).Maximum; $avg = ($gains | Measure-Object -Average).Average
    $at39best = @($gains | Where-Object { $_ -le 0 }).Count
    Write-Host ("  measured: the best height beats -39 by at most {0:+#;-#;0} blocks (average {1:+0.0;-0.0;0}); -39 is already best for {2} of {3}. {4} runs, {5:0.0}s -> main\y_phase.csv" -f `
        $mx, $avg, $at39best, $gains.Count, ($preRuns + $farms.Count * $levels), $secs) -ForegroundColor Cyan
}
Remove-Item $fin, $fout -ErrorAction SilentlyContinue
