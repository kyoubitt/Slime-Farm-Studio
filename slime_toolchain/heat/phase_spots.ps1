# phase_spots.ps1 - EXACT search of spots with the phase model (hotspot_scan --phase-search).
#
# For every -StepX-th / -StepZ-th AFK chunk within +-Rx X / +-Rz Z of a spot (default 15 positions:
# every class whose best was >= 70 on a full grid still reached 64 on this one, 397 of 397), every
# class of the families in the top -TopPct percent by possible chunks there is solved exactly: all
# its layouts over its 8,192 seeds, from 222 numbers (docs\PHASE_MODEL.txt). That is every
# seed of those families at every position - no sampling, no family guessing. Every known record
# family ranks inside the top 1.6% at its farm chunk; searches of ALL families at two positions put
# every 68+ layout inside the top 4.31% and every 70+ inside 3.58% (right at the old 3% cut, kept only
# through ties) - so the default is 5%. Layouts reaching -T chunks are written; a
# shortlist is scored for blocks by slime_refine and every 66+ is archived (ArchiveResult).
# One row per spot in -Out (same SpotBest/BestAt/BestSeed columns as best_family.csv, so
# record_cycle's batch summary works for both). Resumable; STOP_WR respected.
#
# SHORTLIST (what gets refined): the top -RefineTop layouts by BLOCKS at the searched position plus
# the top -RefineByCount by CHUNKS (both are proxies for the refined cq: by chunks alone the 67.07 fell
# outside the top 1,000 at its spot; by blocks alone a 62.46 was lost) plus the top -RefineY39 by the
# RAISED-AFK blocks, the number /perimeterinfo actually reads with the AFK point at y -39 (corr +0.74
# with the in-game value, against +0.37 for cq blocks and +0.21 for chunks - docs\PREDICTION.txt section 10).
# The three rankings are UNIONED, so the -39 slice can only ADD layouts: every seed the older two
# picked is still picked (checked row for row; the regression gate re-found 132 of 132 farms).
# Each with up to -PerLayout
# seeds: seeds with identical chunks inside the searched window can differ in the chunks further out
# that slime_refine also uses (the 66.56 at the 68.28 spot was lost when only one seed per layout was
# kept). Ordering is deterministic (ties broken by seed).
# PIPELINED: a spot's refine runs on the CPU while the next spot's search runs on the GPU.
param([int]$Spots = 10, [string]$SpotFile = "main\best_spots.csv", [int]$T = 64, [int]$Rx = 6, [int]$Rz = 3, [int]$StepX = 3, [int]$StepZ = 3,
      [double]$TopPct = 5, [int]$RefineTop = 400, [int]$RefineByCount = 200, [int]$RefineY39 = 200, [int]$PerLayout = 3, [string]$Exe = "hotspot_scan.exe",
      [int]$CheckEvery = 50,   # every Nth spot searched: the family-cut check (0 = never)
      # search only the best K of the 15 grid positions, ranked by families with >= 150 possible chunks there
      # (0 = all). 97 of 97 test spots kept their best layout at K = 10; regression gate 55/55 at K = 10.
      [int]$TopPositions = 10,
      # RECORD MODE (see the block below): screen each batch first and search only spots whose screen
      # reaches this chunk count. 0 = off. 74 is the measured setting; the record needs 75+.
      [int]$GateCount = 0, [string]$GateFile = "main\theory\heat\gate_skipped.csv",
      [string]$Out = "main\theory\heat\phase_search.csv", [string]$Work = "main\work\phase",
      [switch]$NoLedger)   # re-passes of already-logged spots: no second ledger row
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root "hunt_pipeline.ps1"), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -in 'SaveImage','ArchiveResult','Log-Over66','Add-Y39Image','Ensure-Index','Add-IndexEntry' }, $true)) { Invoke-Expression $fn.Extent.Text }
$Commands = "commands_phase.csv"
$Radius = [math]::Max($Rx, $Rz) + 3          # slime_refine looks this far around the spot for the AFK chunk (farms sit up to ~2 chunks past a searched position)
# Z needs less: searched AFK chunks are only +-Rz in Z, and the best AFK point of all 6,365 refined 65+ farms lay
# within -59..+93 blocks in Z (X: -113..+128). Z radius Rz + 4 (7 = +-112 blocks) was checked 2026-09-13: 12,183
# shortlisted seeds at 17 spots and all 6,365 historical farms refine IDENTICALLY (cq, blocks, AFK x/z) - 1.27x faster.
# (Radius 8 in X was rejected: a farm sat exactly on its +128 edge.)
$RadiusZ = $Rz + 4
$keepDir = "main\theory\heat\phase_layouts"; New-Item -ItemType Directory -Force -Path $keepDir | Out-Null
$done = @{}; if (Test-Path $Out) { foreach ($d in (Import-Csv $Out)) { $done["$($d.X),$($d.Z)"] = 1 } }
$list = @(Import-Csv $SpotFile | Where-Object { -not $done.ContainsKey("$([int]$_.X),$([int]$_.Z)") } | Select-Object -First $Spots)
$work = $Work; New-Item -ItemType Directory -Force -Path $work | Out-Null

# -GateCount: RECORD MODE. A farm's -39 blocks are at most the sum of the largest <count> cell weights
# (the 220 non-zero weights sorted descending), so beating the 19,012 record needs at least 75 slime
# chunks in the window - realistically 77+, since the record itself sits at 95% of what 78 chunks can
# hold. Only 18 of 1,800 searched spots ever produced a 76+ layout. The probe screen costs 0.32 s
# against the exact search's 14 s and NEVER over-states a spot's best count (0 of 400 checked), so it
# is a sound pre-filter: gating at 74 searched 15 of 400 spots and still caught both 76+ spots.
# Gated-out spots go to $GateFile so they are screened once, never searched, and never re-screened;
# they are ordinary-farm ground, not record ground. 0 = off (search every spot, as before).
if ($GateCount -gt 0 -and $list.Count) {
    $skipped = @{}; if (Test-Path $GateFile) { foreach ($d in (Import-Csv $GateFile)) { $skipped["$($d.X),$($d.Z)"] = 1 } }
    $list = @($list | Where-Object { -not $skipped.ContainsKey("$([int]$_.X),$([int]$_.Z)") })
    if ($list.Count) {
        $gi = "$work\gate_in.txt"; $go = "$work\gate_out.csv"
        [IO.File]::WriteAllLines((Join-Path $root "$gi"), [string[]]($list | ForEach-Object { "$([int]$_.X),$([int]$_.Z)" }))
        & (Join-Path $root "phase_prepass.exe") --spots $gi --out $go --probe 8 --exhaust 64 --top-pct 0.25 | Out-Null
        if (Test-Path $go) {
            $best = @{}; foreach ($r in (Import-Csv $go)) { $best["$([int]$r.X),$([int]$r.Z)"] = [int]$r.best }
            $pass = @(); $fail = @()
            foreach ($s in $list) { $k = "$([int]$s.X),$([int]$s.Z)"
                if (-not $best.ContainsKey($k) -or $best[$k] -ge $GateCount) { $pass += $s }
                else { $fail += [pscustomobject]@{ X = [int]$s.X; Z = [int]$s.Z; heat = $s.Heat40; screen_count = $best[$k]; gate = $GateCount; date = (Get-Date -Format 'yyyy-MM-dd HH:mm') } } }
            if ($fail.Count) { if (Test-Path $GateFile) { $fail | Export-Csv $GateFile -NoTypeInformation -Append } else { $fail | Export-Csv $GateFile -NoTypeInformation } }
            "gate {0}: screened {1} spots, {2} pass, {3} parked in {4}" -f $GateCount, $list.Count, $pass.Count, $fail.Count, $GateFile
            $list = @($pass)
        } else { "gate: phase_prepass wrote nothing - searching every spot this batch" }
    }
}

# the first $nKeys layout keys in $sorted order, with up to $PerLayout seeds each
function Take-Layouts($sorted, $nKeys) {
    $per = @{}; $keys = 0
    foreach ($r in $sorted) {
        $k = "$($r.family)|$($r.count)|$($r.blocks)|$($r.dx)|$($r.dz)"
        if (-not $per.ContainsKey($k)) { if ($keys -ge $nKeys) { break }; $per[$k] = 0; $keys++ }
        if ($per[$k] -lt $PerLayout) { $per[$k]++; $r }
    }
}
# the spot's refine is done: archive, keep, log, ledger
function Finish-Spot($P) {
    $tw = Get-Date
    $P.Proc.WaitForExit()
    $script:tRefineWait = ((Get-Date) - $tw).TotalSeconds; $global:tRefineWait = $script:tRefineWait
    $best = $null
    if (Test-Path $P.Scored) {
        $scored = @(Import-Csv $P.Scored | Sort-Object { [double]$_.cq } -Descending); $best = $scored[0]
        # every scored farm of 65+ kept per spot: what this spot was found to hold, for good
        $scored | Where-Object { [double]$_.cq -ge 65.0 } | Export-Csv ("{0}\{1}_{2}_scored.csv" -f $keepDir, $P.X, $P.Z) -NoTypeInformation
        # the spot's 10 best DISTINCT 66+ farms: seeds sharing a layout (up to -PerLayout refined) come back as the
        # same farm - same cq, AFK point equal or a few blocks off - and used to take several of the 10 slots
        $kept = New-Object System.Collections.Generic.List[object]
        foreach ($r in ($scored | Where-Object { [double]$_.cq -ge 66.0 })) {
            if ($kept.Count -ge 10) { break }
            if (@($kept | Where-Object { [double]$_.cq -eq [double]$r.cq -and [math]::Abs([long]$_.x - [long]$r.x) -le 8 -and [math]::Abs([long]$_.z - [long]$r.z) -le 8 }).Count) { continue }
            $kept.Add($r)
            ArchiveResult $r.cq $r.seed $P.X $P.Z ("pipe_{0}_{1}" -f $P.X, $P.Z) $Radius $root ("PHASE@{0},{1}" -f $P.X, $P.Z)
        }
    }
    $g = $P.G
    $row = [pscustomobject]@{ Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); X = $P.X; Z = $P.Z; Line = $P.S.Line; Heat40 = $P.S.Heat40
        Layouts64 = [int]$g[1].Value; Layouts66 = [int]$g[2].Value; Layouts68 = [int]$g[3].Value; Layouts70 = [int]$g[4].Value; BestCount = [int]$g[5].Value
        SpotBest = $(if ($best) { [double]$best.cq } else { 0 }); BestSeed = $(if ($best) { $best.seed } else { "" })
        BestAt = $(if ($best) { "($($best.x),$($best.z))" } else { "" }); Secs = [int]((Get-Date) - $P.T0).TotalSeconds; Refined = $P.N }
    if (Test-Path $Out) { $row | Export-Csv $Out -NoTypeInformation -Append } else { $row | Export-Csv $Out -NoTypeInformation }
    # the shared ledger too (main\families.csv), so every mode (heat_spots, -Heat, ...) sees the spot as done
    if (-not $NoLedger) { [pscustomobject]@{ Key = "PHASE|top$TopPct@$($P.X),$($P.Z)"; Mask = "PHASE"; Val = "top$TopPct"; SpotX = $P.X; SpotZ = $P.Z
        BestCQ = $row.SpotBest; Eff = $(if ($best) { $best.eff_pct } else { 0 }); Chunks = $(if ($best) { $best.chunks_at_best_blocks } else { 0 })
        X = $(if ($best) { $best.x } else { 0 }); Z = $(if ($best) { $best.z } else { 0 }); Seed = $row.BestSeed; Times = 1 } |
        Export-Csv "main\families.csv" -NoTypeInformation -Append }
    "[{0,2}/{1}] ({2},{3}) heat {4}: layouts >=64 {5}, >=66 {6}, >=68 {7}, >=70 {8}; best {9} chunks -> SPOT BEST {10} cq {11}  ({12}s, {13} refined)" -f `
        $P.I, $list.Count, $P.X, $P.Z, $P.S.Heat40, $row.Layouts64, $row.Layouts66, $row.Layouts68, $row.Layouts70, $row.BestCount, $row.SpotBest, $row.BestAt, $row.Secs, $P.N
}

# FAMILY-CUT CHECK: search the spot centre with ALL families and log every 68+ layout whose family
# lies outside the cut (the one assumption of the exact search that is sampled, not proven). Any such
# layout is also refined and archived, so the check is never wasted work.
function Test-Cut($X, $Z, $S) {
    $all = "$work\cutcheck.csv"
    $clog = & (Join-Path $root $Exe) --phase-search --center-x $X --center-z $Z --phase-rx 0 --phase-rz 0 --phase-t 66 --phase-top-pct 100 --phase-keep $all --phase-keep-min 66 2>&1
    $cutLine = $clog | Select-String 'possible >= (\d+)'
    if (-not (Test-Path $all)) { return }
    $n = @{}; foreach ($l in (& (Join-Path $root $Exe) --phase-search --center-x $X --center-z $Z --phase-rx 0 --phase-rz 0 --phase-t 90 --phase-top-pct $TopPct 2>&1 | Select-String 'possible >= (\d+)')) { $n.cut = [int]$l.Matches[0].Groups[1].Value }
    $rows = @(Import-Csv $all); $out = @($rows | Where-Object { [int]$_.possible -lt $n.cut })
    $o68 = @($out | Where-Object { [int]$_.count -ge 68 }); $o70 = @($out | Where-Object { [int]$_.count -ge 70 })
    [pscustomobject]@{ Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); X = $X; Z = $Z; Heat40 = $S.Heat40; CutPossible = $n.cut
        Layouts66 = @($rows | Where-Object { [int]$_.count -ge 66 }).Count; Outside66 = @($out | Where-Object { [int]$_.count -ge 66 }).Count
        Layouts68 = @($rows | Where-Object { [int]$_.count -ge 68 }).Count; Outside68 = $o68.Count
        Layouts70 = @($rows | Where-Object { [int]$_.count -ge 70 }).Count; Outside70 = $o70.Count
        WorstRank70 = [math]::Round((@($rows | Where-Object { [int]$_.count -ge 70 } | ForEach-Object { [double]$_.family_rank_pct }) + 0 | Measure-Object -Maximum).Maximum, 2) } |
        Export-Csv "main\theory\heat\cut_checks.csv" -NoTypeInformation -Append
    if ($o68.Count) {
        "  CUT CHECK ({0},{1}): {2} layouts of 68+ outside the cut - refining them" -f $X, $Z, $o68.Count
        $sf = "$work\cutcheck_seeds.csv"; ($o68 | ForEach-Object seed | Select-Object -Unique) -join ',' | Set-Content $sf -Encoding ascii
        & (Join-Path $root "slime_refine.exe") --seeds $sf --center-x $X --center-z $Z --radius $Radius --csv "$sf.scored" --quiet --no-images --no-logs *> $null
        if (Test-Path "$sf.scored") { foreach ($r in (Import-Csv "$sf.scored" | Where-Object { [double]$_.cq -ge 66.0 })) {
            ArchiveResult $r.cq $r.seed $X $Z ("pipe_{0}_{1}" -f $X, $Z) $Radius $root ("PHASECUT@{0},{1}" -f $X, $Z) } }
    }
}

# ONE search process for the whole batch (hotspot_scan --phase-stdin, 2026-09-22): a spot is one line on its stdin and
# its log ends at PHASE_SPOT_DONE - the CUDA start-up (~0.2 s a spot) is paid once. Same search, same files.
$searcher = $null
function Start-Searcher {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $root $Exe); $psi.WorkingDirectory = $root; $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
    $psi.Arguments = "--phase-search --phase-stdin --phase-rx $Rx --phase-rz $Rz --phase-step-x $StepX --phase-step-z $StepZ --phase-t $T --phase-top-pct $TopPct " +
        "--phase-refine-top $RefineTop --phase-refine-count $RefineByCount --phase-refine-y39 $RefineY39 --phase-per-layout $PerLayout --phase-top-positions $TopPositions"
    [System.Diagnostics.Process]::Start($psi)
}
# Send-Spot starts a spot's search and returns at once; Receive-Spot collects its log. The previous spot's filing
# (Finish-Spot: refine wait, archive, images, ledgers - seconds of CPU at a rich spot) runs in between, while the GPU
# searches (2026-09-22). Same calls in the same order, so every file is the same.
function Send-Spot($X, $Z, $lay, $keep) {
    if (-not $script:searcher -or $script:searcher.HasExited) { $script:searcher = Start-Searcher }
    $script:searcher.StandardInput.WriteLine("$X`t$Z`t$lay`t$keep"); $script:searcher.StandardInput.Flush()
}
function Receive-Spot {
    $lines = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $l = $script:searcher.StandardOutput.ReadLine()
        if ($null -eq $l) { $script:searcher = $null; break }          # the process died: the caller sees no summary, the next spot restarts it
        if ($l.StartsWith('PHASE_SPOT_DONE')) { break }
        $lines.Add($l)
    }
    $lines
}
# FILING WORKER (2026-09-22): Finish-Spot (refine wait, archive, images, ledgers - ~1.5 s per 66+ farm, up to ~9 s at a
# rich spot) runs on ONE background runspace that takes spots strictly in order, so the shared files get the same rows
# in the same order as before, while this loop keeps the GPU searching. Test-Cut waits for it to go idle first.
$fileQ = New-Object 'System.Collections.Concurrent.BlockingCollection[object]'
$fileOut = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:filedQueued = 0; $script:filedDone = 0
$defs = (@('SaveImage', 'ArchiveResult', 'Log-Over66', 'Add-Y39Image', 'Finish-Spot', 'Ensure-Index', 'Add-IndexEntry') | ForEach-Object { "function $_ {`n$((Get-Item "function:$_").ScriptBlock)`n}" }) -join "`n"
$filerRs = [runspacefactory]::CreateRunspace(); $filerRs.Open()
$filer = [powershell]::Create(); $filer.Runspace = $filerRs
[void]$filer.AddScript({
    param($q, $outQ, $defs, $vars)
    foreach ($k in $vars.Keys) { Set-Variable -Name $k -Value $vars[$k] -Scope Global }
    Set-Location $vars['root']
    . ([scriptblock]::Create($defs))
    foreach ($P in $q.GetConsumingEnumerable()) {
        $tf0 = Get-Date
        try { foreach ($line in @(Finish-Spot $P)) { $outQ.Enqueue([string]$line) } }
        catch { $outQ.Enqueue("filing failed at ($($P.X),$($P.Z)): $_") }
        finally { $outQ.Enqueue('__FILED__')
            Add-Content 'main\logs\filing_timing.csv' -Value ('{0},{1},{2},{3:F2},{4:F2}' -f (Get-Date -Format 'HH:mm:ss'), $P.X, $P.Z, $global:tRefineWait, ((Get-Date) - $tf0).TotalSeconds) }
    }
}).AddArgument($fileQ).AddArgument($fileOut).AddArgument($defs).AddArgument(@{
    root = $root; keepDir = $keepDir; Radius = $Radius; Out = $Out; NoLedger = [bool]$NoLedger; TopPct = $TopPct; list = $list; Commands = $Commands })
$filerHandle = $filer.BeginInvoke()
function Queue-Filing($P) { $script:filedQueued++; $fileQ.Add($P) }
function Flush-FilingOutput { $l = $null; while ($fileOut.TryDequeue([ref]$l)) { if ($l -eq '__FILED__') { $script:filedDone++ } else { $l } } }
function Wait-Filing { while ($script:filedDone -lt $script:filedQueued) { Flush-FilingOutput; Start-Sleep -Milliseconds 100 } }
$i = 0; $pending = $null
foreach ($s in $list) {
    $i++; $X = [int]$s.X; $Z = [int]$s.Z; $t0 = Get-Date
    if (Test-Path "main\STOP_WR") { "STOP_WR present - stopping before spot $i"; break }
    # hotspot_scan writes the refine shortlist and the 68+ keep file itself (top -RefineTop layouts by
    # blocks + top -RefineByCount by chunks + top -RefineY39 by the -39 blocks, -PerLayout seeds each) - the
    # full layout list (up to ~70k rows at rich spots) never passes through PowerShell
    $lay = "$work\shortlist.csv"; $keepFile = "{0}\{1}_{2}.csv" -f $keepDir, $X, $Z
    Remove-Item $lay -ErrorAction SilentlyContinue
    $tS = Get-Date
    Send-Spot $X $Z $lay $keepFile
    # the previous spot's refine ran during the last search; file it while the GPU searches this spot
    $script:tRefineWait = 0; $tF = Get-Date
    if ($pending) { Queue-Filing $pending; $pending = $null }
    Flush-FilingOutput
    $tR = Get-Date
    $log = Receive-Spot
    $tE = Get-Date
    # per-spot timing (2026-09-22): refine wait and filing (previous spot), then the wait for this spot's search
    Add-Content "main\logs\phase_spots_timing.csv" -Value ("{0},{1},{2},{3:F2},{4:F2},{5:F2},{6:F2}" -f (Get-Date -Format 'HH:mm:ss'), $X, $Z,
        $script:tRefineWait, (($tR - $tF).TotalSeconds - $script:tRefineWait), ($tE - $tR).TotalSeconds, ($tE - $tS).TotalSeconds)
    $sum = ($log | Select-String 'layouts >= 64: (\d+), >= 66: (\d+), >= 68: (\d+), >= 70: (\d+); best (\d+)').Matches
    if (-not $sum.Count -or -not (Test-Path $lay)) { "phase search failed at ($X,$Z)"; $log | Select-Object -Last 5; continue }
    $rows = @(Import-Csv $lay)
    $sf = "$work\seeds_$i.csv"; $sc = "$work\scored_$i.csv"
    ($rows | ForEach-Object seed) -join ',' | Set-Content $sf -Encoding ascii
    $proc = Start-Process -FilePath (Join-Path $root "slime_refine.exe") -NoNewWindow -PassThru -RedirectStandardOutput "$work\refine_$i.txt" -ArgumentList @(
        "--seeds", $sf, "--center-x", $X, "--center-z", $Z, "--radius", $Radius, "--radius-z", $RadiusZ, "--csv", $sc, "--quiet", "--no-images", "--no-logs")
    try { $proc.PriorityClass = 'BelowNormal' } catch { }   # it has slack in the cycle; the filing worker and the searcher get the CPU first
    $pending = @{ Proc = $proc; Scored = $sc; X = $X; Z = $Z; S = $s; G = $sum[0].Groups; T0 = $t0; I = $i; N = $rows.Count }
    if ($CheckEvery -gt 0 -and (($done.Count + $i) % $CheckEvery) -eq 0) { Wait-Filing; Test-Cut $X $Z $s }
}
if ($pending) { Queue-Filing $pending }
$fileQ.CompleteAdding(); Wait-Filing; [void]$filer.EndInvoke($filerHandle); $filer.Dispose(); $filerRs.Close()
if ($searcher -and -not $searcher.HasExited) { $searcher.StandardInput.Close(); $searcher.WaitForExit() }
Remove-Item "$work\*" -ErrorAction SilentlyContinue
