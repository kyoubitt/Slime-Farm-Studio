# universe_chunk.ps1 - ONE COMPARTMENT, run to completion: screen with heat\universe_screen.ps1 for -Minutes
# (stopped cleanly at a batch boundary), log the screen to main\theory\prediction\UNIVERSE_LOG.md, then
# heat\compartment_finish.ps1: stage 2 (--y39), exact search of EVERY unsearched 74+ candidate, y39_rank.ps1
# over the archive, and a results block. Wall time = -Minutes of screening PLUS ~30-40 s per candidate
# (~40 candidates a compartment, so ~20-25 min more). Each compartment is self-contained and resumable: the screen
# skips spots already in universe_sample.csv, so the next call picks up exactly where this one stopped.
#
#   powershell -ExecutionPolicy Bypass -File heat\universe_chunk.ps1              # 30 minutes
#   powershell -ExecutionPolicy Bypass -File heat\universe_chunk.ps1 -Minutes 15
#
# The screen ranks spots by BEST CHUNK COUNT: -39 blocks are at most the sum of the largest <count> cell
# weights, so beating 19,012 needs 75+ chunks. Measured yield (2026-09-20, first 4,000 spots): 0.45% at
# 74+, and of 18 such spots exact-searched, 2 reached 70+ cq and one - the only 78 - gave a farm the tool
# estimates at 19,103. The same screen over the old measured list found 0 of 3,410.
param([int]$Minutes = 30, [int]$Batch = 1000, [int]$Stride = 1, [switch]$ScreenOnly, [string]$Source = "")   # -ScreenOnly: skip the searches; -Source: spot list (default universe_all.csv if present, else universe_h20.csv)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$pd = "main\theory\prediction"
$file = if ($Stride -gt 1) { "$pd\universe_sample.csv" } else { "$pd\universe_screened.csv" }
$log = "$pd\UNIVERSE_LOG.md"
if (-not $Source) { $Source = "universe_tier1.csv" }   # heat v2 tier 1 (2026-09-22); the v1 lists are archived
$universe = @(Import-Csv "$pd\$Source").Count

function Stat($path) {
    if (-not (Test-Path $path)) { return @{ n = 0; c74 = 0; c76 = 0; c78 = 0; max = 0 } }
    $v = @(Import-Csv $path | ForEach-Object { [int]$_.best })
    @{ n = $v.Count
       c74 = @($v | Where-Object { $_ -ge 74 }).Count
       c76 = @($v | Where-Object { $_ -ge 76 }).Count
       c78 = @($v | Where-Object { $_ -ge 78 }).Count
       max = $(if ($v.Count) { ($v | Measure-Object -Maximum).Maximum } else { 0 }) }
}

if (Test-Path "main\STOP_WR") { "main\STOP_WR is present - remove it first"; exit 1 }
$before = Stat $file
$start = Get-Date
$args0 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'heat\universe_screen.ps1'), '-Batch', $Batch, '-Source', $Source)
if ($Stride -gt 1) { $args0 += @('-Stride', $Stride) }
$hideWin = if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { @{ WindowStyle = 'Hidden' } } else { @{} }   # -WindowStyle is Windows-only
New-Item -ItemType Directory -Force -Path "main\logs" | Out-Null
$p = Start-Process (Get-Process -Id $PID).Path -ArgumentList $args0 -WorkingDirectory $root -PassThru @hideWin `
        -RedirectStandardOutput "main\logs\universe_chunk.log" -RedirectStandardError "main\logs\universe_chunk.err"
"compartment started $(Get-Date -Format 'HH:mm'), running $Minutes minutes (pid $($p.Id))"
$deadline = $start.AddMinutes($Minutes)
while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
if (-not $p.HasExited) {
    New-Item -ItemType File "main\STOP_WR" -Force | Out-Null     # the screen stops at its next batch boundary
    if (-not $p.WaitForExit(300000)) { $p.Kill() }
    Remove-Item "main\STOP_WR" -Force -ErrorAction SilentlyContinue
}
$after = Stat $file
$mins = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
$did = $after.n - $before.n
$rate = $(if ($did -gt 0) { [math]::Round(((Get-Date) - $start).TotalSeconds / $did, 3) } else { 0 })
$pct = [math]::Round(100 * $after.n / $universe, 2)
# $after.n counts THIS file only. A spot is also covered if it was exact-searched, or screened into the
# stride sample / the older screened files - universe_screen.ps1 skips all of those. Reporting one file
# under-states progress (2026-09-21: 11.19% from the file against 20.0% actually covered).
$cov = @{}
foreach ($f in 'main\theory\heat\phase_search.csv', 'main\theory\heat\best_family.csv',
               "$pd\screened.csv", "$pd\rescreened.csv", "$pd\universe_sample.csv", "$pd\universe_screened.csv") {
    if (Test-Path $f) { foreach ($d in (Import-Csv $f)) { if ($d.X) { $cov["$([int]$d.X),$([int]$d.Z)"] = 1 } } } }
$covPct = [math]::Round(100 * $cov.Count / $universe, 2)

$block = @()
$block += ""
$block += "## Compartment $(Get-Date -Format 'yyyy-MM-dd HH:mm')  -  $mins min, $did spots"
$block += ""
$block += "| | this compartment | cumulative |"
$block += "|---|---|---|"
$block += "| spots screened | $did | $($after.n) of $universe ($pct%) in this file |"
$block += "| universe covered | - | **$($cov.Count) of $universe ($covPct%)** incl. searched + sample |"
$block += "| 74+ | $($after.c74 - $before.c74) | $($after.c74) |"
$block += "| 76+ | $($after.c76 - $before.c76) | $($after.c76) |"
$block += "| 78+ | $($after.c78 - $before.c78) | $($after.c78) |"
$block += "| best count seen | - | $($after.max) |"
$block += ""
$block += "Rate $rate s/spot. File: ``$file``. Resumable - the next compartment skips what this one screened."
if (-not (Test-Path $log)) {
    $hdr = @("# Universe screen log", "",
             "One block per compartment of the full screen of ``universe_h20.csv`` ($universe measured spots at heat 20+).",
             "Written by ``heat\universe_chunk.ps1``. The screen ranks by best chunk count, because the -39 record bound",
             "is on count: beating 19,012 needs 75+ chunks. Candidates are exact-searched separately with",
             "``heat\phase_spots.ps1``.", "")
    Set-Content $log -Value $hdr -Encoding UTF8
}
Add-Content $log -Value $block -Encoding UTF8
$block | ForEach-Object { $_ }
# The screen only NOMINATES. A compartment is fully done when its candidates are re-ranked at -39, exact-searched
# and the archive re-ranked (project owner, 2026-09-21) - so that is part of every compartment, not a separate step.
if (-not $ScreenOnly) { & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "heat\compartment_finish.ps1") -Label "after the screen above" }
