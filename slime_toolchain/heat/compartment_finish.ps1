# compartment_finish.ps1 - the SECOND HALF of a compartment. A compartment is FULLY done only when its
# candidates are searched and ranked at -39 (project owner, 2026-09-21), not when the screen stops:
#   screen (universe_chunk.ps1)  ->  stage 2: --y39 re-rank  ->  exact search of EVERY unsearched 74+
#   ->  y39_rank.ps1 over the whole archive  ->  a results block in UNIVERSE_LOG.md
# universe_chunk.ps1 calls this automatically; run it by hand to finish a compartment whose screen already ran.
# Every candidate is searched - the record-range line is a reading of the batch, never a skip.
#
#   powershell -ExecutionPolicy Bypass -File heat\compartment_finish.ps1
param([string]$Label = "")
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$pd = "main\theory\prediction"; $rec = "main\records"; $log = "$pd\UNIVERSE_LOG.md"
if (Test-Path "main\STOP_WR") { "main\STOP_WR is present - remove it first"; exit 1 }
$t0 = Get-Date
New-Item -ItemType Directory -Force -Path "main\logs" | Out-Null
$before = @{}; foreach ($r in (Import-Csv "$rec\over66.csv")) { $before[$r.Seed] = 1 }
$prev1 = (Import-Csv "$rec\y39_all.csv" | Select-Object -First 1)

"stage 2 + exact search of every unsearched 76+ candidate..."
$cand = @(& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "heat\candidates.ps1") -Search 100000 2>&1 | ForEach-Object { "$_" })
$cand | Set-Content "main\logs\compartment_finish.log" -Encoding UTF8
$cand | Where-Object { $_ -match '^record range|^ranked|^re-screening|^no unsearched|^exact-searching' }
"ranking the archive at -39..."
& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "y39_rank.ps1") -Top 0 | Out-Null

$searched = @($cand | Where-Object { $_ -match '^\[\s*\d+/\d+\]' }).Count
$big = @($cand | Where-Object { $_ -match 'BIG' }).Count
$range = @($cand | Where-Object { $_ -match '^record range' }) | Select-Object -First 1
$all = @(Import-Csv "$rec\y39_all.csv")
$new = @($all | Where-Object { -not $before.ContainsKey($_.seed) })
$top = $all[0]
$mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

$b = @("", "### Compartment searches$(if ($Label) { " - $Label" })  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm'), $mins min", "")
if (-not $searched) {
    $b += "No unsearched 76+ candidates - nothing to search."
} else {
    $b += "| | |"; $b += "|---|---|"
    $b += "| candidates exact-searched | $searched |"
    $b += "| BIG flags | $big |"
    $b += "| farms filed | $($new.Count) |"
    if ($new.Count) { $n1 = $new[0]
        $b += "| best new farm | **$($n1.blocks39)** at -39 (cq $($n1.cq)), spot ($($n1.spot_x),$($n1.spot_z)) - archive rank $($n1.rank) |" }
    if ($top.seed -ne $prev1.seed) {
        $b += "| **NEW #1** | **$($top.blocks39)** (cq $($top.cq), seed $($top.seed), AFK $($top.best_x),$($top.best_z)) - was $($prev1.blocks39). MEASURE IT IN GAME |"
    } else { $b += "| archive #1 | $($top.blocks39)$(if ($top.ingame) { " (in game $($top.ingame))" }) - unchanged |" }
    if ($range) { $b += ""; $b += "Stage 2, before searching: $range" }
}
$b += ""; $b += "Full search output: ``main\logs\compartment_finish.log``. Archive ranking: ``main\records\y39_all.csv``."
Add-Content $log -Value $b -Encoding UTF8
$b | ForEach-Object { $_ }
