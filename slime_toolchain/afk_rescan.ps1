# afk_rescan.ps1 - ONE-SHOT sync of the side folder main\records\over70_y-39\ (no loop; new 66+ farms are added
# at filing time by hunt_pipeline's Add-Y39Image). Every 66+ farm's image, named by the number /perimeterinfo
# would read with the player's feet at y -39 over the -64 floor (no inner no-spawn circle, outer circle 125.7;
# AFK point free to move +-48 blocks):
#     18598-69.39-71791501344359.png            the tool's estimate            (peri-score-seed)
#     18409-70.34-136253019324379-measured.png   the measured in-game count (main\records\measured_in_game.csv) - it wins
# Run it after adding an in-game measurement (renames that farm to its measured number), or to backfill.
# Sort by name (or date, newest first) = highest first. NOT a second ranking, not read by the search.
# Calibrated in game: a full floor at -39 reads 49,669 (afk_rescan --disc: 49,669); exact for 69.30 / 68.28 /
# 66.04, +20 for 70.64, but off by ~200 for 70.34 / 69.09 - an estimate to check, never a claim. -39 only (project owner).
param([int]$Window = 48, [switch]$Refresh)   # -Refresh: re-copy every image in the folder from its record image (names and dates kept)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$rec = "main\records"; $dst = "$rec\over70_y-39"; $work = "main\work\rescan"
New-Item -ItemType Directory -Force -Path $dst, $work | Out-Null
if (-not (Test-Path "$rec\over66.csv")) {
    Write-Host "afk_rescan.ps1: no main\records\over66.csv yet - nothing to sync. This backfills the y -39 image gallery from farms YOUR hunt has already filed; this copy ships no record archive. Run record_cycle.ps1 -PhaseSearch -BestFamilySpots main\best_spots.csv first - new 66+ farms are added automatically at filing time." -ForegroundColor Yellow
    exit 0 }

function Put-Image($src, $num, $cq, $seed, $suffix) {     # copy (images have no inner ring), name by the number, date-stamp by it
    $p = Join-Path $dst ("{0}-{1}-{2}{3}.png" -f $num, $cq, $seed, $suffix)
    Copy-Item -LiteralPath $src $p -Force
    $stamp = ([datetime]'2026-01-01').AddSeconds(5 * [double]$num); (Get-Item -LiteralPath $p).LastWriteTime = $stamp; (Get-Item -LiteralPath $p).CreationTime = $stamp
}
$have = @{}; foreach ($f in (Get-ChildItem $dst -Filter *.png)) { if ($f.Name -match '^\d+-[\d.]+-(-?\d+)(-measured)?\.png$') { $have[$Matches[1]] = $f } }
$mBy = @{}; if (Test-Path "$rec\measured_in_game.csv") { foreach ($m in (Import-Csv "$rec\measured_in_game.csv")) { $mBy[$m.seed] = $m } }
$todo = New-Object System.Collections.Generic.List[object]; $n = 0
foreach ($r in (Import-Csv "$rec\over66.csv")) {
    if (-not $r.X) { continue }
    if ([double]$r.CQ -lt 70) { continue }     # galleries are 70+ only (project owner, 2026-09-22)
    $src = "{0}\{1}\{2}_{3}.png" -f $rec, [math]::Floor([double]$r.CQ), $r.CQ, $r.Seed
    if (-not (Test-Path -LiteralPath $src)) { $src = "{0}\over70_images\{1}_{2}.png" -f $rec, $r.CQ, $r.Seed }   # hand-filed records (RECORD.*)
    if (-not (Test-Path -LiteralPath $src)) { continue }
    if ($mBy.ContainsKey($r.Seed)) {              # measured: the in-game number, replacing any estimate
        $want = "{0}-{1}-{2}-measured.png" -f $mBy[$r.Seed].ingame, $r.CQ, $r.Seed
        if (-not $have.ContainsKey($r.Seed) -or $have[$r.Seed].Name -ne $want) {
            if ($have.ContainsKey($r.Seed)) { Remove-Item -LiteralPath $have[$r.Seed].FullName -Force }
            Put-Image $src $mBy[$r.Seed].ingame $r.CQ $r.Seed "-measured"; $n++ }
        continue }
    if (-not $have.ContainsKey($r.Seed)) { $todo.Add([pscustomobject]@{ seed = $r.Seed; x = $r.X; z = $r.Z; cq = $r.CQ; src = $src }) }
}
if ($todo.Count) {
    $in = "$work\y39_in.csv"; $out = "$work\y39_out.csv"
    @("seed,x,z,cq") + @($todo | ForEach-Object { "{0},{1},{2},{3}" -f $_.seed, $_.x, $_.z, $_.cq }) | Set-Content $in -Encoding ascii
    & (Join-Path $root "afk_rescan.exe") --in $in --out $out --dy 24 --window $Window | Out-Null
    $srcBy = @{}; foreach ($t in $todo) { $srcBy[$t.seed] = $t.src }
    if (Test-Path $out) { foreach ($o in (Import-Csv $out)) { Put-Image $srcBy[$o.seed] ([int]$o.blocks_dy_best) $o.cq $o.seed ""; $n++ } }
    Remove-Item $in, $out -ErrorAction SilentlyContinue
}
if ($Refresh) {
    $bySeed = @{}; foreach ($r in (Import-Csv "$rec\over66.csv")) { $bySeed[$r.Seed] = $r }; $k = 0
    foreach ($f in (Get-ChildItem $dst -Filter *.png)) { if ($f.Name -match '^\d+-[\d.]+-(-?\d+)(-measured)?\.png$') { $r = $bySeed[$Matches[1]]; if (-not $r) { continue }
        $src = "{0}\{1}\{2}_{3}.png" -f $rec, [math]::Floor([double]$r.CQ), $r.CQ, $r.Seed; if (-not (Test-Path -LiteralPath $src)) { $src = "{0}\over70_images\{1}_{2}.png" -f $rec, $r.CQ, $r.Seed }
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $stamp = $f.LastWriteTime; Copy-Item -LiteralPath $src $f.FullName -Force; (Get-Item -LiteralPath $f.FullName).LastWriteTime = $stamp; (Get-Item -LiteralPath $f.FullName).CreationTime = $stamp; $k++ } }
    "refreshed $k images from the record images" }
"over70_y-39: {0} image(s) added/renamed, {1} in the folder" -f $n, @(Get-ChildItem $dst -Filter *.png).Count
