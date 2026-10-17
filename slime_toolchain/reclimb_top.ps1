# reclimb_top.ps1 - DEEP-climb the best seeds already found, looking for a new record
# without hunting anything new.
#
# Why: every spot has one best-possible farm, and re-hunting it with new masks mostly
# re-finds what it already gave. But the climb is a different instrument - it walks a
# seed's high bits - and the wide 28-bit window (bits 20-47) beats the normal 24-bit
# one on seeds that are already good (65.55 -> 66.31, 64.71 -> 65.05, 64.00 -> 64.44).
# The best seeds in main\records\index.csv were mostly only ever climbed the normal
# way, so this re-climbs the top -Top of them the deep way (~2-3 min each on the laptop).
#
# Uses hunt_pipeline.ps1's own Climb-Seed / ArchiveResult (loaded from its source), so
# an improvement is filed exactly like a hunt result: main\records\<tier>\ + index.csv,
# and the family's ledger entry in main\families.csv is raised to the new best.
#   -Extra "seed,spotX,spotZ,cq;..."  seeds not in the index (e.g. an in-game-verified
#                                      RECORD.* file) to include as well
param([int]$Top = 6, [int]$Lo = 20, [int]$Bits = 28,
      [string]$Extra = "9029506488461633794,3680,6992,66.04")
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root "hunt_pipeline.ps1"), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -in 'Invoke-ClimbScan','Climb-Seed','SaveImage','ArchiveResult','Ensure-Index','Add-IndexEntry','Log-Over66','Add-Y39Image' }, $true)) { Invoke-Expression $fn.Extent.Text }
# Log-Over66 and Add-Y39Image were missing here before 2026-10-03: ArchiveResult calls both at its end, so an
# improvement filed by this script never got its over66.csv row or its -39 image.
foreach ($need in 'ArchiveResult', 'Ensure-Index', 'Add-IndexEntry', 'Log-Over66', 'Add-Y39Image') {
    if (-not (Get-Command $need -ErrorAction SilentlyContinue)) { throw "borrowed function $need did not load" } }
$Radius = 6; $script:worker = $null; $Commands = "commands_reclimb.csv"   # ArchiveResult reads $Commands for the Run column

# Already covered: a deep climb searched every seed sharing its low $Lo bits at that spot
$done = @{}
if (Test-Path main\records\deep_climbed.csv) {
    foreach ($d in (Import-Csv main\records\deep_climbed.csv)) { if ([int]$d.Lo -le $Lo) { $done["$($d.SpotX)_$($d.SpotZ)_$([int64]$d.Seed -band ((1L -shl $Lo) - 1))"] = 1 } }
}
if (-not (Test-Path 'main\records\index.csv')) {
    Write-Host "reclimb_top.ps1: no main\records\index.csv - this re-climbs the best seeds ALREADY FOUND, and this copy ships no record archive. Only the built-in -Extra seed (the 66.04 record) will be climbed. Run record_cycle.ps1 -PhaseSearch -BestFamilySpots main\best_spots.csv first, then come back." -ForegroundColor Yellow }
function Test-Done($seed, $sx, $sz) { $done.ContainsKey("${sx}_${sz}_$([int64]$seed -band ((1L -shl $Lo) - 1))") }
# best seed per SPOT (one spot = one best-possible farm), skipping covered ones
$all = @(Import-Csv main\records\index.csv -ErrorAction SilentlyContinue | Where-Object { $_.Seed -and $_.SpotX } |
    ForEach-Object { [pscustomobject]@{ Seed=$_.Seed; SpotX=[int]$_.SpotX; SpotZ=[int]$_.SpotZ; CQ=[double]$_.CQ; Family=$_.Family } })
foreach ($e in ($Extra -split ';' | Where-Object { $_.Trim() })) {
    $p = $e.Split(','); $all += [pscustomobject]@{ Seed=$p[0]; SpotX=[int]$p[1]; SpotZ=[int]$p[2]; CQ=[double]$p[3]; Family="" } }
$cands = @($all | Sort-Object CQ -Descending | Group-Object SpotX,SpotZ | ForEach-Object { $_.Group[0] } |
    Where-Object { -not (Test-Done $_.Seed $_.SpotX $_.SpotZ) } | Select-Object -First $Top)
Write-Host ("{0} spots to deep-climb (best seed per spot, not already covered)" -f $cands.Count)
$fam = @(if (Test-Path main\families.csv) { Import-Csv main\families.csv })
$changed = $false
foreach ($c in ($cands | Sort-Object CQ -Descending)) {
    $t0 = Get-Date
    Write-Host ("{0:0.00}  seed {1}  spot ({2},{3}) - deep climb bits {4}-47..." -f $c.CQ, $c.Seed, $c.SpotX, $c.SpotZ, $Lo)
    $row = [pscustomobject]@{ seed = $c.Seed; cq = [string]$c.CQ }
    $b = Climb-Seed $row $c.SpotX $c.SpotZ $Lo $Bits "deep climb"
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    if ([double]$b.cq -gt $c.CQ) {
        Write-Host ("      IMPROVED {0:0.00} -> {1} cq, {2} chunks at ({3},{4}), seed {5}  ({6}s)" -f $c.CQ, $b.cq, $b.chunks_at_best_blocks, $b.x, $b.z, $b.seed, $secs) -ForegroundColor Green
        ArchiveResult $b.cq $b.seed $c.SpotX $c.SpotZ ("pipe_{0}_{1}" -f $c.SpotX, $c.SpotZ) $Radius $root $c.Family
        foreach ($f in $fam) { if ($f.Seed -eq $c.Seed -and [double]$b.cq -gt [double]$f.BestCQ) {
            $f.BestCQ = $b.cq; $f.Eff = $b.eff_pct; $f.Chunks = $b.chunks_at_best_blocks; $f.X = $b.x; $f.Z = $b.z; $f.Seed = $b.seed; $changed = $true } }
    } else { Write-Host ("      no improvement ({0}s)" -f $secs) -ForegroundColor DarkGray }
}
if ($changed) { $fam | Export-Csv main\families.csv -NoTypeInformation; Write-Host "ledger updated" }
Get-ChildItem main\work -File -Filter 'climb*' -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
