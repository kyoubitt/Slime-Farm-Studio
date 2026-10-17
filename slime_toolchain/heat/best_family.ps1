# best_family.ps1 - value a spot by the seed family it is BEST in, and search that family.
#
# Heat is an average over every seed. A record farm is not average: it comes from one
# rare "rich" 20-bit family (1-3 per million) that is rich only at that farm. So a spot's
# real record potential is its best family, found like this:
#   1. SWEEP all 1,048,576 families with the WINDOWED sweep (hotspot_scan --family-sweep
#      --sweep-rx 3 --sweep-rz 2): a seed counts when the farm reaches -SweepFloor chunks
#      at ANY AFK chunk within +-3 X, +-2 Z of the spot. The old single-position sweep
#      (heat\deep_spots.ps1) only looked at the centre, and farms sit 0-3 chunks away:
#      at the 66.63 spot its family scored 1 hit at the centre (rank 5, noise); windowed,
#      from the same centre, it ranks #1 of 1,048,576 with 17 hits (next best 7).
#      ~150 s per spot on the laptop at 50k seeds / floor 64.
#   2. CONFIRM the top -Confirm families: -ConfirmSeeds random seeds each (slime_gpu,
#      24-chunk window, floor 64).
#   3. EXHAUST the -Exhaust best confirmed families (and any other near record class): all 2^28 seeds (--enumerate), keep
#      layouts >= 70 chunks, score them, archive 66+ (hunt_pipeline's ArchiveResult),
#      ledger each family as 0xFFFFF|val@x,z so nothing is searched twice. -NoExhaust
#      stops after step 2 (spot value only).
# Output: -Out (default main\theory\heat\best_family.csv), one row per spot:
#   Top1/Top2/Top3 = sweep hits of the three best families (the spot's best-family
#   value), Top1At = where the best family's best hit sat (chunk offset from the spot),
#   confirm hits, exhaust results and SpotBest (best farm from the exhausted families).
param([int]$Spots = 20, [string]$SpotFile = "", [int]$SweepSeeds = 50000, [int]$SweepFloor = 64,
      [int]$Rx = 3, [int]$Rz = 2, [int]$Confirm = 8, [int]$ConfirmSeeds = 2000000,
      [int]$Exhaust = 2, [int]$ExhaustSeconds = 150, [switch]$NoExhaust,
      # plus any further family whose confirm reached -ExtraMinConfirm hits (up to -MaxExhaust in all).
      # Calibration 2026-09-11 (2M-seed confirm hits -> best farm when exhausted): 4981 -> 68.28,
      # 2137 -> 66.63, 2063 -> 66.84, 1458 -> 64.46, 1435 -> 66.17, 1421 -> 66.61, 795 -> 64.86,
      # 234 -> 63.30, 204 -> 62.20. An exhaust costs ~40 s against a ~150 s sweep, so every
      # family near record class gets one.
      [int]$ExtraMinConfirm = 700, [int]$MaxExhaust = 4,
      # DEAD SPOT: best family under -DeadTop1 sweep hits and no family confirmed at -ExtraMinConfirm
      # -> no exhaust (saves ~80 s). 2026-09-11, 22 spots: best family >= 10 sweep hits -> 4 of 6
      # spots had a 66+ farm; under 10 -> 0 of 16 (best 63.36). 0 = always exhaust.
      [int]$DeadTop1 = 5,
      [string]$Out = "main\theory\heat\best_family.csv")
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root "hunt_pipeline.ps1"), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -in 'SaveImage','ArchiveResult','Log-Over66','Add-Y39Image','Ensure-Index','Add-IndexEntry' }, $true)) { Invoke-Expression $fn.Extent.Text }
$Commands = "commands_deep.csv"; $Radius = 6
if (-not $SpotFile) { $SpotFile = "main\work\best_family_spots.csv"; & (Join-Path $root "heat\best_spots.ps1") -Count $Spots -Out $SpotFile | Out-Null }   # the measured list (heat_spots.ps1 retired)
# RESUMABLE: a spot already in -Out is done (its families are swept, confirmed, exhausted
# and ledgered) - skip it, so a long run can be stopped and restarted on the same list.
$done = @{}; if (Test-Path $Out) { foreach ($d in (Import-Csv $Out)) { $done["$($d.X),$($d.Z)"] = 1 } }
$list = @(Import-Csv $SpotFile | Where-Object { -not $done.ContainsKey("$([int]$_.X),$([int]$_.Z)") } | Select-Object -First $Spots)
if ($done.Count) { "{0} spots already in {1} skipped; {2} to do" -f $done.Count, $Out, $list.Count }
$ledgerPath = "main\families.csv"; $ledger = [ordered]@{}
if (Test-Path $ledgerPath) { foreach ($e in (Import-Csv $ledgerPath)) { $ledger[$e.Key] = $e } }
$work = "main\work\bestfam"; New-Item -ItemType Directory -Force -Path $work | Out-Null
$i = 0
foreach ($s in $list) {
    $i++; $X = [int]$s.X; $Z = [int]$s.Z; $t0 = Get-Date
    if (Test-Path "main\STOP_WR") { "STOP_WR present - stopping before spot $i"; break }
    # 1. windowed sweep of every family
    $sw = "$work\sweep.csv"; Remove-Item $sw -ErrorAction SilentlyContinue
    & .\hotspot_scan.exe --family-sweep --center-x $X --center-z $Z --sweep-mask 0xFFFFF --sweep-n 1048576 --sweep-seeds $SweepSeeds `
        --sweep-floor $SweepFloor --sweep-rx $Rx --sweep-rz $Rz --rng-seed 7 --sweep-out $sw *> $null
    if (-not (Test-Path $sw)) { "sweep failed at ($X,$Z)"; continue }
    $top = @(Import-Csv $sw | Select-Object -First $Confirm)
    $h = @($top | ForEach-Object { [int]$_.hits }) + @(0, 0, 0)
    # 2. confirm the top families with many more seeds
    $conf = foreach ($f in ($top | Where-Object { [int]$_.hits -gt 0 })) {
        $log = & .\slime_gpu.exe --seed-count $ConfirmSeeds --center-x $X --center-z $Z --m-chunks 24 --fix-mask 0xFFFFF --fix-val $f.val `
            --record-floor 64 --seeds-floor 999 --report-every 1000000000 --give-up-after 0 --rng-seed 5 --seeds-out "$work\_c.csv" 2>&1
        $n = 0; $mm = ($log | Select-String 'FINAL: (\d+) hits').Matches; if ($mm.Count) { $n = [int]$mm[0].Groups[1].Value }
        [pscustomobject]@{ val = $f.val; sweepHits = [int]$f.hits; confirmHits = $n }
    }
    $conf = @($conf | Sort-Object confirmHits -Descending)
    # 3. exhaust the strongest confirmed families
    $spotBest = 0.0; $spotSeed = ""; $spotAt = ""; $exh = @()
    $dead = $DeadTop1 -gt 0 -and $h[0] -lt $DeadTop1 -and -not @($conf | Where-Object { $_.confirmHits -ge $ExtraMinConfirm }).Count
    if ($dead) { $exh += "dead-spot:no-exhaust" }
    $toExhaust = if ($NoExhaust -or $dead) { @() } else { @($conf | Where-Object { $_.confirmHits -gt 0 } | Select-Object -First $Exhaust) + @($conf | Select-Object -Skip $Exhaust | Where-Object { $_.confirmHits -ge $ExtraMinConfirm } | Select-Object -First ([math]::Max(0, $MaxExhaust - $Exhaust))) }
    foreach ($c in $toExhaust) {
        $key = "0xFFFFF|$($c.val)@$X,$Z"
        if ($ledger.Contains($key)) {       # searched before: count its result, do not redo it
            $bcq = [double]$ledger[$key].BestCQ; $exh += ("{0}:done:{1}" -f $c.val, $bcq)
            if ($bcq -gt $spotBest) { $spotBest = $bcq; $spotSeed = $ledger[$key].Seed; $spotAt = "($($ledger[$key].X),$($ledger[$key].Z))" }
            continue }
        $sf = "$work\f_$($c.val).csv"; Remove-Item $sf -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath (Join-Path $root "slime_gpu.exe") -NoNewWindow -PassThru -RedirectStandardOutput "$work\_e.txt" -ArgumentList @(
            "--seed-count","0","--center-x",$X,"--center-z",$Z,"--m-chunks","24","--fix-mask","0xFFFFF","--fix-val",$c.val,
            "--record-floor","70","--seeds-floor","70","--report-every","1000000000","--give-up-after","0","--enumerate","--enum-start","0","--seeds-out",$sf)
        # 2^28 seeds take ~37 s alone on the laptop; sharing the GPU can double that. A family cut
        # off part-way is scored and archived but NOT ledgered, so it is searched again in full.
        $timedOut = $false
        if (-not $p.WaitForExit($ExhaustSeconds * 1000)) { $p.Kill(); $timedOut = $true; $exh += "$($c.val):TIMEOUT" }
        $best = $null; $n70 = 0
        if ((Test-Path $sf) -and (Get-Item $sf).Length -gt 0) {
            $n70 = @((Get-Content $sf -Raw).Split(',') | Where-Object { $_.Trim() }).Count
            & .\slime_refine.exe --seeds $sf --center-x $X --center-z $Z --radius $Radius --csv "$sf.scored" --quiet --no-images --no-logs *> $null
            if (Test-Path "$sf.scored") {
                $scored = @(Import-Csv "$sf.scored" | Sort-Object { [double]$_.cq } -Descending); $best = $scored[0]
                $seen = @{}
                foreach ($r in ($scored | Where-Object { [double]$_.cq -ge 66.0 } | Select-Object -First 5)) {
                    if ($seen.ContainsKey("$($r.x),$($r.z),$($r.cq)")) { continue }; $seen["$($r.x),$($r.z),$($r.cq)"] = 1
                    ArchiveResult $r.cq $r.seed $X $Z ("pipe_{0}_{1}" -f $X, $Z) $Radius $root $key
                }
            }
        }
        if (-not $timedOut) { $ledger[$key] = [pscustomobject]@{ Key=$key; Mask='0xFFFFF'; Val=$c.val; SpotX=$X; SpotZ=$Z
            BestCQ=$(if ($best) { $best.cq } else { 0 }); Eff=$(if ($best) { $best.eff_pct } else { 0 }); Chunks=$(if ($best) { $best.chunks_at_best_blocks } else { 0 })
            X=$(if ($best) { $best.x } else { 0 }); Z=$(if ($best) { $best.z } else { 0 }); Seed=$(if ($best) { $best.seed } else { "" }); Times=1 } }
        $bcq = if ($best) { [double]$best.cq } else { 0 }
        $exh += ("{0}:{1}x70:{2}" -f $c.val, $n70, $bcq)
        if ($bcq -gt $spotBest) { $spotBest = $bcq; $spotSeed = $best.seed; $spotAt = "($($best.x),$($best.z))" }
    }
    if (-not $NoExhaust) { $ledger.Values | Export-Csv $ledgerPath -NoTypeInformation }   # after every spot
    $row = [pscustomobject]@{ Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); X = $X; Z = $Z; Line = $s.Line; Heat40 = $s.Heat40
        Top1Val = $(if ($top.Count) { $top[0].val } else { "" }); Top1 = $h[0]; Top2 = $h[1]; Top3 = $h[2]
        Top1At = $(if ($top.Count -and $top[0].PSObject.Properties['best_dx']) { "$($top[0].best_dx),$($top[0].best_dz)" } else { "" })
        TopConfirm = (($conf | Select-Object -First 3 | ForEach-Object { "$($_.val):$($_.confirmHits)" }) -join ' ')
        Exhausted = ($exh -join ' '); SpotBest = $spotBest; BestSeed = $spotSeed; BestAt = $spotAt; Secs = [int]((Get-Date) - $t0).TotalSeconds }
    if (Test-Path $Out) { $row | Export-Csv $Out -NoTypeInformation -Append } else { $row | Export-Csv $Out -NoTypeInformation }
    "[{0,2}/{1}] ({2},{3}) heat {4}: best families {5}/{6}/{7} hits; confirm {8}; exhausted {9} -> SPOT BEST {10}  ({11}s)" -f `
        $i, $list.Count, $X, $Z, $s.Heat40, $h[0], $h[1], $h[2], $row.TopConfirm, $row.Exhausted, $spotBest, $row.Secs
}
Remove-Item "$work\*" -ErrorAction SilentlyContinue
