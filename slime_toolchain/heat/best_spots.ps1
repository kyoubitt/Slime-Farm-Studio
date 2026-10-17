# best_spots.ps1 - the hottest spots in the world from the RE-MEASURED X and line values.
# heat ~ F(X) x G(Z) (heat\factor_fit.ps1: the product model fits 29k measured spots).
#   F(X): main\theory\heat\x_rescore.csv - heat40 of every distinct X peak in the survey,
#         measured directly on line 10617 (heat\x_rescore.ps1, 300k seeds), the top 600
#         re-measured at 2M (x_confirm.csv). Replaces the survey's pass-1 variance, which
#         barely predicts real X value: the true top 240 sit at survey ranks up to 15,000
#         (median 3,702), and the #1 column (heat 32) was survey rank 12,893.
#   G(Z): main\theory\heat\line_rescore.csv - the top 60 lines, each averaged over the same
#         40 X peaks at 2M seeds (heat\line_rescore.ps1; agrees with the fit at r = 0.98).
# Predicted heat40 of (X, line) = F(X) x G(line) / G(10617). Spots already in -Skip (done by
# heat\best_family.ps1) are left out, as is anything within 4 chunks in X on the same line
# of one (the same farm). Output: -Out, columns X, Z, Line, Heat40 (predicted), XHeat, LineV.
# -Bins "32,28,24,20,16,12" -PerBin 6: a STRATIFIED list instead - -PerBin random spots in each
# predicted-heat band (all measured X columns x the 60 lines), hottest band first. It tests
# whether heat predicts record-class families at all (proposal 1, 2026-09-12).
param([int]$Count = 500, [string]$Out = "main\best_spots.csv", [string]$Skip = "main\theory\heat\best_family.csv",
      [string]$Bins = "", [int]$PerBin = 6, [int]$Seed = 12,
      [int]$Lines = 150,   # lines from the full line survey (line_world_ranked.csv), best first
      [int]$XTop = 1500)   # X peaks paired with them (the list is hottest-first, so the top X suffice)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$HD = "main\theory\heat"
if (-not (Test-Path "$HD\x_rescore.csv") -or -not (Test-Path "$HD\line_rescore.csv")) {
    Write-Host "best_spots.ps1: the heat-survey inputs ($HD\x_rescore.csv, $HD\line_rescore.csv) are not part of this copy." -ForegroundColor Yellow
    Write-Host "Keeping the shipped main\best_spots.csv (500 pre-ranked spots) unchanged." -ForegroundColor Yellow
    return }
# the 2M-seed re-measure of the leaders (x_rescore -ConfirmTop) replaces their 300k value
$xc = @{}; if (Test-Path "$HD\x_confirm.csv") { foreach ($r in (Import-Csv "$HD\x_confirm.csv")) { $xc[$r.cx] = $r.heat40 } }
$xv = @(Import-Csv "$HD\x_rescore.csv" | ForEach-Object { if ($xc.ContainsKey($_.cx)) { $_.heat40 = $xc[$_.cx] }; $_ } | Sort-Object { [double]$_.heat40 } -Descending)
# the whole world width (GPU heat survey, heat\x_world.ps1) replaces the old list when present
if (Test-Path "$HD\x_world.csv") { $xv = @(Import-Csv "$HD\x_world.csv" | Sort-Object { [double]$_.heat40 } -Descending) }
$lv = @(Import-Csv "$HD\line_rescore.csv" | Sort-Object { [double]$_.mean_heat40 } -Descending)
# every line inside the border (GPU line survey, heat\line_world.ps1) replaces the proxy-picked 60 when
# present: its top -Lines, scaled to the same unit (line 10617 = its re-measured value)
if (Test-Path "$HD\line_world_ranked.csv") { $lv = @(Import-Csv "$HD\line_world_ranked.csv" | Select-Object -First $Lines) }
$ref = [double]($lv | Where-Object { $_.line_n -eq '10617' }).mean_heat40
if (Test-Path "$HD\line_world_ranked.csv") { $ref = 19.99 }   # line_world_ranked.csv is scaled so line 10617 = 19.99 (it need not be in the top -Lines)
$skipRows = @{}
foreach ($sk in ($Skip -split ',' | Where-Object { $_ -and (Test-Path $_) })) { foreach ($d in (Import-Csv $sk)) { $r = [int][math]::Floor([double]$d.Z / 16)
    if (-not $skipRows.ContainsKey($r)) { $skipRows[$r] = New-Object System.Collections.Generic.List[int] }
    $skipRows[$r].Add([int][math]::Floor([double]$d.X / 16)) } }
function Near($cx, $row) { for ($dr = -2; $dr -le 2; $dr++) { $l = $skipRows[$row + $dr]; if ($l) { foreach ($h in $l) { if ([math]::Abs($h - $cx) -le 4) { return $true } } } }; return $false }
if ($Bins) {
    $edges = @($Bins -split ',' | ForEach-Object { [double]$_ }); $rng = New-Object System.Random $Seed
    $picked = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -lt $edges.Count - 1; $k++) {
        $hi = $edges[$k]; $lo = $edges[$k + 1]; $got = 0
        for ($try = 0; $try -lt 200000 -and $got -lt $PerBin; $try++) {
            $x = $xv[$rng.Next($xv.Count)]; $l = $lv[$rng.Next($lv.Count)]
            $h = [double]$x.heat40 * [double]$l.mean_heat40 / $ref
            if ($h -ge $hi -or $h -lt $lo) { continue }
            $cx = [int]$x.cx; $row = [int]$l.row
            if (Near $cx $row) { continue }
            $picked.Add([pscustomobject]@{ X = $cx * 16; Z = $row * 16; Line = [int]$l.line_n; Heat40 = [math]::Round($h, 1); XHeat = [double]$x.heat40; LineV = [double]$l.mean_heat40 })
            if (-not $skipRows.ContainsKey($row)) { $skipRows[$row] = New-Object System.Collections.Generic.List[int] }
            $skipRows[$row].Add($cx); $got++
        }
        "heat {0}-{1}: {2} spots" -f $lo, $hi, $got
    }
    $picked | Export-Csv $Out -NoTypeInformation; return
}
# MEASURED spots (heat\spot_top.ps1, from the direct GPU spot survey) replace the X x line prediction
# when present: the product model mis-ranks the top (X heat across lines r = 0.3 among the hottest X).
if (Test-Path "$HD\spot_top.csv") {
    $picked = New-Object System.Collections.Generic.List[object]
    foreach ($c in (Import-Csv "$HD\spot_top.csv")) {
        if ($picked.Count -ge $Count) { break }
        $cx = [int]$c.cx; $row = [int]$c.cz
        if (Near $cx $row) { continue }
        $picked.Add([pscustomobject]@{ X = $cx * 16; Z = $row * 16; Line = [int]$c.line_n; Heat40 = [math]::Round([double]$c.heat40, 1); XHeat = ''; LineV = '' })
        if (-not $skipRows.ContainsKey($row)) { $skipRows[$row] = New-Object System.Collections.Generic.List[int] }
        $skipRows[$row].Add($cx)    # the same farm is not offered twice
    }
    $picked | Export-Csv $Out -NoTypeInformation
    "{0} spots -> {1}: MEASURED heat40 {2} .. {3}" -f $picked.Count, $Out, $picked[0].Heat40, $picked[$picked.Count - 1].Heat40
    return
}
# Only the top few hundred X peaks can reach the top -Count on any line (line values span
# ~1.3x across the top 60), so the candidate grid stays small.
$cand = New-Object System.Collections.Generic.List[object]
foreach ($x in ($xv | Select-Object -First $XTop)) { foreach ($l in $lv) {
    $cand.Add([pscustomobject]@{ cx = [int]$x.cx; row = [int]$l.row; Line = [int]$l.line_n
        Heat40 = [math]::Round([double]$x.heat40 * [double]$l.mean_heat40 / $ref, 1); XHeat = [double]$x.heat40; LineV = [double]$l.mean_heat40 }) } }
$picked = New-Object System.Collections.Generic.List[object]
foreach ($c in ($cand | Sort-Object Heat40 -Descending)) {
    if ($picked.Count -ge $Count) { break }
    if (Near $c.cx $c.row) { continue }
    $picked.Add([pscustomobject]@{ X = $c.cx * 16; Z = $c.row * 16; Line = $c.Line; Heat40 = $c.Heat40; XHeat = $c.XHeat; LineV = $c.LineV })
}
$picked | Export-Csv $Out -NoTypeInformation
"{0} spots -> {1}: predicted heat40 {2} .. {3}" -f $picked.Count, $Out, $picked[0].Heat40, $picked[$picked.Count - 1].Heat40
