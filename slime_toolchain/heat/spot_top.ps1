# spot_top.ps1 - after the direct spot survey (hotspot_scan --heat-spots over the top X peaks x top lines,
# main\theory\heat\spot_measured.csv, ~3M rows): keep the hottest -Keep spots (fast reader, no Import-Csv
# of the whole file), re-measure the top -Confirm at -ConfirmSeeds, and write main\theory\heat\spot_top.csv
# (cx, cz, line_n, heat40, heat40_300k, seeds) - the list heat\best_spots.ps1 ranks spots by.
# Why measured and not predicted: among the 150 hottest X columns of line 10617, their heat on lines
# 9950 / 4850 correlated at only r = 0.3 - "X value x line value" mis-ranks the top.
param([string]$In = "main\theory\heat\spot_measured.csv", [int]$Keep = 20000, [double]$MinHeat = 24, [int]$Confirm = 3000, [long]$ConfirmSeeds = 2000000,
      [string]$Out = "main\theory\heat\spot_top.csv")
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
# one pass: keep every spot at or above -MinHeat (the top of the list is far above it), then sort
$keepRows = New-Object 'System.Collections.Generic.List[double[]]'; $n = 0
foreach ($l in [IO.File]::ReadLines((Join-Path $root "$In"))) { $n++; if ($n -eq 1) { continue }
    $c2 = $l.LastIndexOf(','); $c1 = $l.LastIndexOf(',', $c2 - 1); $h = [double]$l.Substring($c1 + 1, $c2 - $c1 - 1)
    if ($h -ge $MinHeat) { $p3 = $l.Split(','); $keepRows.Add([double[]]@($h, [double]$p3[0], [double]$p3[1])) } }
$top = @($keepRows | Sort-Object { $_[0] } -Descending | Select-Object -First $Keep)
"{0:N0} spots read; {1:N0} at heat40 >= {2}; kept the top {3:N0} (heat40 {4:F1} .. {5:F1})" -f ($n - 1), $keepRows.Count, $MinHeat, $top.Count, $top[0][0], $top[-1][0]# re-measure the leaders
$cf = Join-Path $root "main\work\spot_confirm_in.txt"; [IO.File]::WriteAllLines($cf, [string[]]($top | Select-Object -First $Confirm | ForEach-Object { "{0},{1}" -f [int]$_[1], [long]$_[2] }))
& (Join-Path $root "hotspot_scan.exe") --heat-spots $cf --heat-seeds $ConfirmSeeds --heat-out "$root\main\work\spot_confirm_out.csv" *> $null
$conf = @{}; foreach ($r in (Import-Csv "$root\main\work\spot_confirm_out.csv")) { $conf["$($r.cx),$($r.cz)"] = [double]$r.heat40 }
$rows = foreach ($t in $top) { $k = "{0},{1}" -f [int]$t[1], [long]$t[2]
    [pscustomobject]@{ cx = [int]$t[1]; cz = [long]$t[2]; line_n = [int][math]::Round(([long]$t[2] - 48.5) / 96.875)
        heat40 = $(if ($conf.ContainsKey($k)) { $conf[$k] } else { $t[0] }); heat40_300k = $t[0]; seeds = $(if ($conf.ContainsKey($k)) { $ConfirmSeeds } else { 300000 }) } }
$rows = @($rows | Sort-Object heat40 -Descending)
$rows | Export-Csv $Out -NoTypeInformation
foreach ($h in 34, 32, 30, 28) { "spots at measured heat40 >= {0}: {1}" -f $h, @($rows | Where-Object { $_.heat40 -ge $h }).Count }
"top 10:"; $rows | Select-Object -First 10 | ForEach-Object { "  X {0,10}  Z {1,10}  line {2,6}  heat40 {3,6:F2}  (300k said {4,6:F2})" -f ($_.cx * 16), ($_.cz * 16), $_.line_n, $_.heat40, $_.heat40_300k }
