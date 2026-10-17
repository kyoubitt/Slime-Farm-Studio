# heat_of.ps1 -X <block> -Z <block> : how hot is this spot? Best of the 3x3 chunks
# around it (a farm centre can sit a chunk off), exact Java model.
param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Z, [int]$Samples = 5000000)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Add-Type -Path "$root\heat\SlimeModel.cs"
$c = [int][math]::Floor($X / 16); $d = [int][math]::Floor($Z / 16); $cx = @(); $cz = @()
foreach ($i in -1..1) { foreach ($j in -1..1) { $cx += $c + $i; $cz += $d + $j } }
$r = [SlimeModel]::DiscPairs([int[]]$cx, [int[]]$cz, $Samples, 40, 45, 50, 9)
$b = 0..8 | Sort-Object { $r[$_][1] } -Descending | Select-Object -First 1
$line = [math]::Round(($d - 48.5) / 96.875); $off = $d - (48.5 + 96.875 * $line)
"spot ({0},{1}): heat40 {2:F1}  heat45 {3:F1}  var {4:F3}   nearest hot line n={5} ({6:+0.0;-0.0} rows from its centre)" -f `
    $X, $Z, ($r[$b][1]/2.1e-5), ($r[$b][2]/6.7e-7), $r[$b][0], $line, $off
"reference: median lattice spot 1 | 66.21 record spot ~10 | 66.04 record spot ~16 | hottest in the world ~24-26 (heat40)"
