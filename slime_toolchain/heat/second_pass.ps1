# second_pass.ps1 - SECOND LOOK at the near misses of the universe screen (2026-09-22). The fast screen (probe 8,
# exhaust 64, top 0.25%) never overstates a spot's best count but can understate it: over 445 exact-searched spots the
# true best was 1-5 higher at 10%, and a stronger screen raised 443 of 2,000 tier-1 spots (one from 68 to 74). A record
# needs 75+ true chunks, so spots screened -MinPass..(-Gate - 1) get the stronger stage-2 screen (probe 8, exhaust 128, top 1%,
# 0.032 s/spot); its rows go to second_pass.csv, and every one at 74+ is exact-searched here (heat\phase_spots.ps1),
# then y39_rank.ps1 and a line in UNIVERSE_LOG.md. SEPARATE from the main compartments (project owner, 2026-09-22): the main
# screen, candidates.ps1 and compartment_finish.ps1 never read second_pass.csv.
# Resumable (spots already in second_pass.csv or exact-searched are skipped); STOP_WR stops it between batches.
#
#   powershell -ExecutionPolicy Bypass -File heat\second_pass.ps1              # floor 68 (project owner, 2026-09-22: cheap insurance below the measured 69)
#   powershell -ExecutionPolicy Bypass -File heat\second_pass.ps1 -Max 20000   # one section
#
# Floor 69 is measured (2026-09-22, main\work\second_pass_study): stage 2 on ~9,100 screened tier-1 spots raised spots
# first screened 69-73 to 74+ (one from 69 to 75+) and none of ~4,600 at 64-68. pairs68 separates the risers (median
# 59 vs 3) but one had 3, so it only ORDERS the work (richest first) - no spot is dropped.
param([int]$MinPass = 74, [int]$Gate = 76, [int]$Batch = 5000, [int]$Max = 0)   # $Gate must match candidates.ps1 -MinCount   # -Max: at most this many spots this run (0 = all)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$pd = "main\theory\prediction"; $work = "main\work\second_pass"; New-Item -ItemType Directory -Force -Path $work | Out-Null
$src = "$pd\universe_screened.csv"; $out = "$pd\second_pass.csv"
if (-not (Test-Path $src)) { "no $src yet"; return }
$skip = @{}
foreach ($f in 'main\theory\heat\phase_search.csv', 'main\theory\heat\best_family.csv', $out) {
    if (Test-Path $f) { foreach ($d in (Import-Csv $f)) { $skip["$([int]$d.X),$([int]$d.Z)"] = 1 } } }
$todo = @(Import-Csv $src | Where-Object { $_.mode -eq 'chunks' -and [int]$_.best -ge $MinPass -and [int]$_.best -lt $Gate -and
    -not $skip.ContainsKey("$([int]$_.X),$([int]$_.Z)") } | Sort-Object { [int]$_.pairs68 } -Descending)
if ($Max -gt 0 -and $todo.Count -gt $Max) { $todo = $todo[0..($Max - 1)] }
if (-not $todo.Count) { "second pass: nothing new at $MinPass..$($Gate-1)"; return }
"second pass: $($todo.Count) spots screened $MinPass..$($Gate-1) get the stage-2 screen"
$t0 = Get-Date; $up = 0; $hit = 0; $stopped = $false; $did = 0
for ($i = 0; $i -lt $todo.Count; $i += $Batch) {
    if (Test-Path "main\STOP_WR") { "STOP_WR present - stopping"; $stopped = $true; break }
    $part = $todo[$i..([math]::Min($i + $Batch, $todo.Count) - 1)]
    [IO.File]::WriteAllLines((Join-Path $root "$work\in.txt"), [string[]]($part | ForEach-Object { "$([int]$_.X),$([int]$_.Z)" }))
    & (Join-Path $root "phase_prepass.exe") --spots "$work\in.txt" --out "$work\out.csv" --probe 8 --exhaust 128 --top-pct 1 | Out-Null
    $first = @{}; foreach ($p in $part) { $first["$([int]$p.X),$([int]$p.Z)"] = $p }
    $rows = foreach ($r in (Import-Csv "$work\out.csv")) {
        $n = 0; if (-not [int]::TryParse($r.best, [ref]$n) -or $n -lt 0 -or $n -gt 226 -or $r.best_family -notmatch '^0x') { continue }
        $k = "$([int]$r.X),$([int]$r.Z)"; if (-not $first.ContainsKey($k)) { continue }
        $f1 = [int]$first[$k].best; if ($n -gt $f1) { $up++ }; if ($n -ge $Gate) { $hit++ }
        [pscustomobject]@{ X = [int]$r.X; Z = [int]$r.Z; heat = $first[$k].heat; best = $n; mode = 'chunks'; first_best = $f1
            pairs68 = $r.pairs68; fam66 = $r.families66; best_dx = $r.best_dx; best_dz = $r.best_dz; best_family = $r.best_family } }
    if (Test-Path $out) { $rows | Export-Csv $out -NoTypeInformation -Append } else { $rows | Export-Csv $out -NoTypeInformation }
    $n = [math]::Min($i + $Batch, $todo.Count); $did = $n; $el = ((Get-Date) - $t0).TotalSeconds
    "  $n of $($todo.Count) ($([int]$el)s): raised $up, now ${Gate}+: $hit"
}

# paused (STOP_WR) before this run screened anything: no search, no log line - the next run picks up here
if ($stopped -and -not $did) { return }
# its 74+ spots: exact search, archive ranking, a log line
$searched = @{}; if (Test-Path 'main\theory\heat\phase_search.csv') { foreach ($d in (Import-Csv 'main\theory\heat\phase_search.csv')) { $searched["$([int]$d.X),$([int]$d.Z)"] = 1 } }
$picks = @(Import-Csv $out | Where-Object { [int]$_.best -ge $Gate -and -not $searched.ContainsKey("$([int]$_.X),$([int]$_.Z)") } | Sort-Object { [int]$_.best } -Descending)
"second pass: $($picks.Count) unsearched spots at ${Gate}+ to exact-search"
if ($picks.Count) {
    $picks | ForEach-Object { [pscustomobject]@{ X = [int]$_.X; Z = [int]$_.Z; Line = ''; Heat40 = $_.heat } } | Export-Csv "$work\picks.csv" -NoTypeInformation
    & (Join-Path $root "heat\phase_spots.ps1") -SpotFile "$work\picks.csv" -Spots $picks.Count -Work main\work\second_pass_run | Where-Object { $_ -match '^\[|BIG' }
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "y39_rank.ps1") -Top 0 | Out-Null
}
$top = Import-Csv 'main\records\y39_all.csv' | Select-Object -First 1
Add-Content "$pd\UNIVERSE_LOG.md" -Encoding UTF8 -Value ("`n## Second pass $(Get-Date -Format 'yyyy-MM-dd HH:mm') - stage-2 screen of screened $MinPass..$($Gate-1): $did of $($todo.Count) spots$(if ($stopped) { ' (paused)' }), raised $up, ${Gate}+ $hit, exact-searched $($picks.Count); archive #1 now $($top.blocks39) at -39`n")

