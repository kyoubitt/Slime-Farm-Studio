# rescreen.ps1 - ONE-SHOT re-screen of spots already screened by the OLD prediction screen (512 random classes per
# family), which found a spot's true exact best only 34% of the time. The probe screen (phase_prepass --probe, see
# main\theory\docs\PREDICTION.txt section 8) finds it 84-94% of the time at the same price, so the ~16,000 spots screened
# before 2026-09-20 and never picked are worth looking at again - a 76+ spot could be sitting in them.
# Screens every unsearched screened spot, writes main\theory\prediction\rescreened.csv, then runs the normal exact
# search on the top -Exact (heat\phase_spots.ps1; farms filed as always). Stoppable: main\STOP_WR between batches,
# and re-running resumes (spots already in rescreened.csv are skipped).
param([int]$Exact = 40, [int]$Batch = 1000, [int]$Max = 0, [switch]$ScreenOnly)   # -Max: stop after this many spots (0 = all)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$pd = "main\theory\prediction"; $work = "main\work\predict"; New-Item -ItemType Directory -Force -Path $pd, $work | Out-Null
$out = "$pd\rescreened.csv"
$searched = @{}
foreach ($f in 'main\theory\heat\phase_search.csv', 'main\theory\heat\best_family.csv') { if (Test-Path $f) { foreach ($d in (Import-Csv $f)) { $searched["$($d.X),$($d.Z)"] = 1 } } }
$done = @{}; if (Test-Path $out) { foreach ($d in (Import-Csv $out)) { $done["$($d.X),$($d.Z)"] = 1 } }
$todo = @(Import-Csv "$pd\screened.csv" | Where-Object { -not $searched.ContainsKey("$($_.X),$($_.Z)") -and -not $done.ContainsKey("$($_.X),$($_.Z)") })
if ($Max -gt 0 -and $todo.Count -gt $Max) { $todo = $todo[0..($Max - 1)] }
"re-screen: $($todo.Count) spots left of $((Import-Csv "$pd\screened.csv").Count) screened ($($done.Count) already re-screened, $($searched.Count) exact-searched)"
$heatBy = @{}; foreach ($d in (Import-Csv "$pd\screened.csv")) { $heatBy["$($d.X),$($d.Z)"] = $d }
for ($i = 0; $i -lt $todo.Count; $i += $Batch) {
    if (Test-Path "main\STOP_WR") { "STOP_WR present - stopping"; break }
    $part = $todo[$i..([math]::Min($i + $Batch, $todo.Count) - 1)]
    [IO.File]::WriteAllLines((Join-Path $root "$work\rescreen_in.txt"), [string[]]($part | ForEach-Object { "$($_.X),$($_.Z)" }))
    & (Join-Path $root "phase_prepass.exe") --spots "$work\rescreen_in.txt" --out "$work\rescreen_out.csv" --probe 8 --exhaust 64 --top-pct 0.25 | Out-Null
    $rows = foreach ($r in (Import-Csv "$work\rescreen_out.csv")) { $h = $heatBy["$($r.X),$($r.Z)"]
        [pscustomobject]@{ X = $r.X; Z = $r.Z; heat = $(if ($h) { $h.heat } else { '' }); line = $(if ($h) { $h.line } else { '' })
            best = $r.best; pairs68 = $r.pairs68; fam66 = $r.families66; old_best = $(if ($h) { $h.best512 } else { '' }) } }
    if (Test-Path $out) { $rows | Export-Csv $out -NoTypeInformation -Append } else { $rows | Export-Csv $out -NoTypeInformation }
    "  {0} of {1} re-screened, best so far {2}" -f [math]::Min($i + $Batch, $todo.Count), $todo.Count, (@(Import-Csv $out | ForEach-Object { [int]$_.best } | Sort-Object -Descending)[0])
}
if ($ScreenOnly) { return }
$all = @(Import-Csv $out | Where-Object { -not $searched.ContainsKey("$($_.X),$($_.Z)") })
$picks = @($all | Sort-Object @{ e = { [int]$_.best }; Descending = $true }, @{ e = { [int]$_.pairs68 }; Descending = $true } | Select-Object -First $Exact)
if (-not $picks.Count) { "nothing to search"; return }
"exact search of the top $($picks.Count) (screen best {0}..{1})" -f $picks[0].best, $picks[-1].best
$picks | ForEach-Object { [pscustomobject]@{ X = $_.X; Z = $_.Z; Line = $_.line; Heat40 = $_.heat } } | Export-Csv "$work\picks.csv" -NoTypeInformation
& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "heat\phase_spots.ps1") -SpotFile "$work\picks.csv" -Spots $picks.Count | Where-Object { $_ -match '^\[|BIG' }
