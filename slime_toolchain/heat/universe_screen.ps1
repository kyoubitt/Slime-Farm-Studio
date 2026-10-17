# universe_screen.ps1 - screen a heat-sorted spot list (default since 2026-09-22: universe_tier1.csv, the heat v2 tier 1).
# Before that: main\theory\prediction\universe_h20.csv (now in the original working copy (NOT SHIPPED)), every measured spot
# down to heat 20 (183,536 of them, chunk coordinates, sorted by heat). Its top 19,740 rows ARE the old heat-24
# list, already screened and partly exact-searched; those are skipped, so this walks the ~164,000 spots at heat
# 20-24 that have never been looked at.
#
# Screened by BEST CHUNK COUNT (default) because that is what the record bound is on: -39 blocks are at most the
# sum of the largest <count> cell weights, so beating 19,012 needs 75+ chunks and no layout below that can matter
# however good its geometry. -Y39 switches to the raised-AFK blocks instead, which ranks ORDINARY farms better
# (+0.74 with the in-game number against +0.21 for count - docs\PREDICTION.txt 10-11) but cannot express the bound.
#
# One-shot and resumable: spots already in the output are skipped, STOP_WR between batches stops it, re-running
# continues. It only SCREENS - the exact search of the picks is a separate call to heat\phase_spots.ps1.
#
#   powershell -ExecutionPolicy Bypass -File heat\universe_screen.ps1 -Max 20000      # the gate slice
#   powershell -ExecutionPolicy Bypass -File heat\universe_screen.ps1                 # the rest
# -Stride N: screen every Nth spot of the (heat-sorted) universe - a systematic sample spread evenly over
# the whole heat range, so its density of 74+ spots multiplies by N to estimate the whole universe, and its
# rows are an unbiased training set for "what predicts a spot's best chunk count". Taking the TOP 1/N
# instead would tell us nothing about the rest: every biased-sample mistake this project has made (the
# geometry prior at -0.29, the 2-4% heat bands) came from measuring on spots that were already selected.
# -Y39: screen by raised-AFK blocks instead of chunk count. Default is COUNT, which is what the record
# bound is on (19,012 needs 75+ chunks) and what the search gate uses.
param([int]$Batch = 5000, [int]$Max = 0, [int]$Stride = 1, [switch]$Y39, [string]$Source = "universe_tier1.csv")   # -Source: heat-sorted cx,cz,heat list in main\theory\prediction (universe_tier1.csv = heat v2 catalog tier 1, heat40 22+, 331,595 spots)   # -Max: stop after this many NEW spots (0 = all)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$pd = "main\theory\prediction"; $work = "main\work\universe"; New-Item -ItemType Directory -Force -Path $pd, $work | Out-Null
$out = if ($Stride -gt 1) { "$pd\universe_sample.csv" } else { "$pd\universe_screened.csv" }
# Two instances appending to the same file is the only thing that explains compartment 1's 987 duplicate rows
# AND its 10,948 NUL bytes (interleaved writes). One screen at a time, per output file.
$lock = "$work\$(Split-Path $out -Leaf).lock"
if (Test-Path $lock) {
    $other = (Get-Content $lock -TotalCount 1)
    if (Get-Process -Id $other -ErrorAction SilentlyContinue) { "another screen (pid $other) is writing $out - stopping"; exit 1 }
    "stale lock from pid $other removed" }
Set-Content $lock -Value $PID -Encoding ascii
try {
$seen = @{}
foreach ($f in 'main\theory\heat\phase_search.csv', 'main\theory\heat\best_family.csv') {
    if (Test-Path $f) { foreach ($d in (Import-Csv $f)) { $seen["$([int]$d.X),$([int]$d.Z)"] = 1 } } }
foreach ($f in "$pd\screened.csv", "$pd\rescreened.csv") {
    if (Test-Path $f) { foreach ($d in (Import-Csv $f)) { $seen["$([int]$d.X),$([int]$d.Z)"] = 1 } } }
$already = $seen.Count
# Export-Csv -Append THROWS on a file whose header does not match the rows being written, and it throws per
# batch - the run looks healthy in the log while saving nothing (2026-09-20: 4,500 spots screened and lost
# to four leftover rows in the old --y39 schema). Refuse to start instead of discovering it later.
if (Test-Path $out) {
    $hdr = (Get-Content $out -TotalCount 1)
    if ($hdr -notmatch '"best"') {
        "$out has an incompatible header ($hdr) - move it aside before screening, or rows will be dropped"; exit 1 }
    # A guard on WRITE does not clean rows that are already in the file. 2026-09-21: universe_screened.csv held
    # 10,948 NUL bytes and 9 torn rows written before the shape test existed - one of them read as 135 chunks and
    # came back as a phantom 79-chunk spot in a tail estimate. Sweep the whole file every run, not just new rows.
    $raw = [IO.File]::ReadAllBytes((Join-Path $root "$out"))
    if ([Array]::IndexOf($raw, [byte]0) -ge 0) {   # native search; `$raw -contains 0` walked ~5 MB byte by byte in PowerShell (~40 s) [IO.File]::WriteAllBytes((Join-Path $root "$out.nul"), $raw)
        [IO.File]::WriteAllBytes((Join-Path $root "$out"), ($raw | Where-Object { $_ -ne 0 })) }
    $all = @(Import-Csv $out)
    $clean = @($all | Where-Object {
        $n = 0; $bx = 0L; $bz = 0L
        [int]::TryParse($_.best, [ref]$n) -and $n -ge 0 -and $n -le 226 -and $_.best_family -match '^0x' -and
        [long]::TryParse($_.X, [ref]$bx) -and [long]::TryParse($_.Z, [ref]$bz) -and
        [math]::Abs($bx) -le 30000000 -and [math]::Abs($bz) -le 30000000 })
    if ($clean.Count -ne $all.Count) {
        Copy-Item $out "$out.prefilter" -Force
        $clean | Export-Csv $out -NoTypeInformation
        "swept $out : dropped $($all.Count - $clean.Count) malformed row(s), $($clean.Count) kept (backup .prefilter)" }
    foreach ($d in $clean) { $seen["$([int]$d.X),$([int]$d.Z)"] = 1 } }
# the list is parsed by a small compiled helper (cx,cz,heat, optionally quoted, every -Stride-th row, minus spots already
# seen): the same loop in PowerShell took 25 s for the 331k-row tier 1 list, Import-Csv before it most of a minute
if (-not ('UniverseList' -as [type])) { Add-Type -TypeDefinition @"
using System; using System.Collections.Generic;
public class UniverseSpot { public int X; public int Z; public string heat; }
public static class UniverseList {
    public static List<UniverseSpot> Todo(string path, int stride, System.Collections.IDictionary seen) {
        var lines = System.IO.File.ReadAllLines(path); var hdr = lines[0].Replace("\"", "").Split(',');
        int ix = Array.IndexOf(hdr, "cx"), iz = Array.IndexOf(hdr, "cz"), ih = Array.IndexOf(hdr, "heat"), mx = Math.Max(ix, Math.Max(iz, ih));
        var res = new List<UniverseSpot>();
        for (int i = 1; i < lines.Length; i += stride) {
            var f = lines[i].Replace("\"", "").Split(','); if (f.Length <= mx) continue;
            long X = long.Parse(f[ix]) * 16, Z = long.Parse(f[iz]) * 16;
            string k = X + "," + Z; if (seen.Contains(k)) continue;
            res.Add(new UniverseSpot { X = (int)X, Z = (int)Z, heat = f[ih] });
        }
        return res;
    }
}
"@ }
$todo = [UniverseList]::Todo((Join-Path $root "$pd\$Source"), $Stride, $seen).ToArray()
if ($Max -gt 0 -and $todo.Count -gt $Max) { $todo = $todo[0..($Max - 1)] }
"universe screen: $($todo.Count) new spots this run (heat $($todo[0].heat)..$($todo[-1].heat)); $already spots already screened or searched, $(@($clean).Count) already in this file"
$modeArg = @(); if ($Y39) { $modeArg = @("--y39") }
# --floor 64 (2026-10-03): the count bound that prunes a layout. 16% faster, and verified IDENTICAL on every
# result column over 3,000 real tier-1 spots in this exact config (main\work\fixverify, floor 60 vs 64 - only
# the `seconds` timing column moved). It is safe because nothing below 64 is read any more: the search gate is
# 76 (candidates.ps1 -MinCount) and the second pass covers 74-75. NOT applied in -Y39 mode, where the same
# change moved `best` on 4 of 3,000 spots - candidates.ps1 does the -39 re-rank and keeps the floor at 60.
if (-not $Y39) { $modeArg += @("--floor", "64") }
$t0 = Get-Date
# progress line: best so far and top-4 mean kept from the rows as they are written (2026-09-22) - re-reading the whole
# output file every batch cost more than the screen itself once the file held tens of thousands of rows
$bestAll = [int[]]@(if ($clean) { $clean.best }); [Array]::Sort($bestAll); [Array]::Reverse($bestAll)
$top = [System.Collections.Generic.List[int]]@($bestAll | Select-Object -First 4)
for ($i = 0; $i -lt $todo.Count; $i += $Batch) {
    if (Test-Path "main\STOP_WR") { "STOP_WR present - stopping"; break }
    $part = $todo[$i..([math]::Min($i + $Batch, $todo.Count) - 1)]
    [IO.File]::WriteAllLines((Join-Path $root "$work\in.txt"), [string[]]($part | ForEach-Object { "$($_.X),$($_.Z)" }))
    & (Join-Path $root "phase_prepass.exe") --spots "$work\in.txt" --out "$work\out.csv" --probe 8 --exhaust 64 --top-pct 0.25 @modeArg | Out-Null
    $heatBy = @{}; foreach ($p in $part) { $heatBy["$($p.X),$($p.Z)"] = "$($p.heat)" }
    # phase_prepass occasionally writes a short or field-shifted line (4 of 8,606 on 2026-09-20; one of them
    # read as 135 chunks, which the 226-cell window makes impossible). Drop anything that fails the shape
    # test HERE, so a corrupt row never reaches the file and never inflates a max.
    $rows = foreach ($r in (Import-Csv "$work\out.csv")) {
        $n = 0; $okNum = [int]::TryParse($r.best, [ref]$n)
        if (-not $okNum -or $n -lt 0 -or $n -gt 226) { continue }
        if ($r.best_family -notmatch '^0x') { continue }
        $bx = 0L; $bz = 0L                                    # a short line also leaves X/Z padded or unparseable
        if (-not [long]::TryParse($r.X, [ref]$bx) -or -not [long]::TryParse($r.Z, [ref]$bz)) { continue }
        if ([math]::Abs($bx) -gt 30000000 -or [math]::Abs($bz) -gt 30000000) { continue }
        [pscustomobject]@{ X = $bx; Z = $bz; heat = $heatBy["$bx,$bz"]
            best = $n; mode = $(if ($Y39) { "blocks39" } else { "chunks" }); pairs68 = $r.pairs68
            fam66 = $r.families66; best_dx = $r.best_dx; best_dz = $r.best_dz; best_family = $r.best_family } }
    if (Test-Path $out) { $rows | Export-Csv $out -NoTypeInformation -Append } else { $rows | Export-Csv $out -NoTypeInformation }
    $n = [math]::Min($i + $Batch, $todo.Count)
    $top = [System.Collections.Generic.List[int]]@(@($top) + @($rows | ForEach-Object { [int]$_.best }) | Sort-Object -Descending | Select-Object -First 4)
    $el = ((Get-Date) - $t0).TotalSeconds
    $t4 = [int](($top | Measure-Object -Average).Average)
    "  $n of $($todo.Count) screened ($([int]$el)s, $([math]::Round($el / $n, 3)) s/spot) - best so far $($top[0]), top-4 mean $t4"
}
"done: $(@(Import-Csv $out).Count) spots in $out"
} finally { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
