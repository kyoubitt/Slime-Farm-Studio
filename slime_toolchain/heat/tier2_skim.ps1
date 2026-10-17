# tier2_skim.ps1 - screen tier 2 in heat45 order, best first, in batches, and report the quality of each batch
# so the run can be cut off when it stops paying. Tier 2 = catalogue heat40 17-22 (the band heat45's top 10%
# lives in); the order comes from the heat45 tail-heat read (main\work\heat45\heat45.csv).
#
# Separate from the tier-1 files on purpose: screens into main\theory\prediction\tier2_screened.csv and searches
# into main\theory\heat\tier2_search.csv, so universe_screened.csv / phase_search.csv stay tier-1 only. Farms are
# filed into the normal archive (index.csv, over66.csv, y39_all.csv) - a farm is a farm.
#
#   powershell -ExecutionPolicy Bypass -File heat\tier2_skim.ps1 -Batches 4
# Resumable: it skips spots already in tier2_screened.csv. Create main\STOP_WR to stop after the current batch.
param([int]$Batch = 25000, [int]$Batches = 1, [int]$Gate = 76, [switch]$NoSearch)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$pd = "main\theory\prediction"; $work = "main\work\tier2"
New-Item -ItemType Directory -Force -Path $work, "main\theory\heat" | Out-Null
$order = "$work\order.csv"
$scr = "$pd\tier2_screened.csv"

# one-time: sort the heat45 read, best first
if (-not (Test-Path $order)) {
    $src = "main\work\heat45\heat45.csv"
    if (-not (Test-Path $src)) { "no heat45 read at $src"; exit 1 }
    "sorting the heat45 read, best first..."
    $rows = [System.Collections.Generic.List[object]]::new()
    $first = $true
    foreach ($line in [IO.File]::ReadLines((Resolve-Path $src))) {
        if ($first) { $first = $false; continue }
        $p = $line.Split(',')
        if ($p.Count -lt 3) { continue }
        $rows.Add([pscustomobject]@{ cx = $p[0]; cz = $p[1]; h45 = [double]$p[2] })
    }
    $rows = @($rows | Sort-Object h45 -Descending)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("cx,cz,heat45")
    foreach ($r in $rows) { [void]$sb.AppendLine("$($r.cx),$($r.cz),$($r.h45)") }
    [IO.File]::WriteAllText((Join-Path $root "$order"), $sb.ToString())
    "ordered $($rows.Count) tier-2 spots -> $order"
}

$done = @{}
if (Test-Path $scr) {
    foreach ($line in [IO.File]::ReadLines((Resolve-Path $scr))) {
        $p = $line.Trim('"') -split '","'
        if ($p.Count -ge 2) { $done["$($p[0]),$($p[1])"] = 1 }
    }
}
"$($done.Count) tier-2 spots already screened"

$all = [IO.File]::ReadAllLines((Join-Path $root "$order"))
$hdr = -not (Test-Path $scr)
$searchedFile = "main\theory\heat\tier2_search.csv"
$already = @{}
foreach ($f in $searchedFile, 'main\theory\heat\phase_search.csv') {
    if (Test-Path $f) { foreach ($d in (Import-Csv $f)) { $already["$([int]$d.X),$([int]$d.Z)"] = 1 } }
}

for ($b = 1; $b -le $Batches; $b++) {
    if (Test-Path "main\STOP_WR") { "STOP_WR set - stopping before batch $b"; break }
    # next $Batch unscreened spots in heat45 order
    $pick = [System.Collections.Generic.List[string]]::new()
    $h45lo = ""; $h45hi = ""
    for ($i = 1; $i -lt $all.Count -and $pick.Count -lt $Batch; $i++) {
        $p = $all[$i].Split(',')
        $x = [int]$p[0] * 16; $z = [int]$p[1] * 16
        if ($done.ContainsKey("$x,$z")) { continue }
        if (-not $h45hi) { $h45hi = $p[2] }
        $h45lo = $p[2]
        $pick.Add("$x,$z") | Out-Null
        $done["$x,$z"] = 1
    }
    if (-not $pick.Count) { "no unscreened tier-2 spots left"; break }
    [IO.File]::WriteAllLines((Join-Path $root "$work\in.txt"), [string[]]$pick)
    $t0 = Get-Date
    & (Join-Path $root "phase_prepass.exe") --spots "$work\in.txt" --out "$work\out.csv" --probe 8 --exhaust 64 --top-pct 0.25 --floor 64 | Out-Null
    $el = ((Get-Date) - $t0).TotalSeconds
    if (-not (Test-Path "$work\out.csv")) { "phase_prepass wrote nothing"; break }

    $rows = @(Import-Csv "$work\out.csv")
    $n74 = 0; $n76 = 0; $n78 = 0; $sum = 0; $best = 0
    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $rows) {
        $c = [int]$r.best; $sum += $c
        if ($c -gt $best) { $best = $c }
        if ($c -ge 74) { $n74++ }
        if ($c -ge 76) { $n76++ }
        if ($c -ge 78) { $n78++ }
        if ($c -ge $Gate -and -not $already.ContainsKey("$([int]$r.X),$([int]$r.Z)")) { $hits.Add($r) | Out-Null }
    }
    # append to the tier-2 screen record
    $sb = [System.Text.StringBuilder]::new()
    if ($hdr) { [void]$sb.AppendLine('"X","Z","heat45","best","mode"'); $hdr = $false }
    foreach ($r in $rows) { [void]$sb.AppendLine('"' + $r.X + '","' + $r.Z + '","","' + $r.best + '","chunks"') }
    [IO.File]::AppendAllText((Join-Path $root "$scr"), $sb.ToString())

    "batch {0}: {1} spots in {2:N0}s ({3:N4} s/spot), heat45 {4}..{5} | mean {6:N1} best {7} | 74+ {8} 76+ {9} 78+ {10}" -f `
        $b, $rows.Count, $el, ($el / $rows.Count), $h45hi, $h45lo, ($sum / $rows.Count), $best, $n74, $n76, $n78

    # AUTO-STOP (project owner 2026-10-03): tier 1's final batch ran 74+ 3.29e-3 and 76+ 4.51e-4, i.e. 0.58 h per
    # 19,000+ farm. Half those rates on a $Batch-spot batch is the cut: below it, tier 2 is worse than the
    # thing we just finished, so stop rather than keep paying. Farms already found in this batch are kept.
    $min74 = [math]::Round($Batch * 3.29e-3 / 2); $min76 = [math]::Round($Batch * 4.51e-4 / 2)
    $poor = ($n74 -lt $min74) -or ($n76 -lt $min76)
    if ($poor) { "   BELOW THE TIER-1 BENCHMARK (needs 74+ >= $min74 and 76+ >= $min76) - this is the last batch" }

    if ($hits.Count -and -not $NoSearch) {
        [IO.File]::WriteAllLines((Join-Path $root "$work\picks.csv"), [string[]](@("X,Z") + @($hits | ForEach-Object { "$([int]$_.X),$([int]$_.Z)" })))
        "   exact-searching $($hits.Count) spots at $Gate+..."
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "heat\phase_spots.ps1") `
            -SpotFile "$work\picks.csv" -Spots $hits.Count -Out $searchedFile -Work "$work\run" -NoLedger |
            Where-Object { $_ -match 'SPOT BEST|BIG' }
        foreach ($h in $hits) { $already["$([int]$h.X),$([int]$h.Z)"] = 1 }
    } elseif (-not $hits.Count) {
        "   nothing at $Gate+ in this batch"
    }
    if ($poor) { "stopping: batch $b fell below the tier-1 benchmark"; break }
}
"done - $($done.Count) tier-2 spots screened in total"
