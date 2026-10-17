# record_cycle.ps1 - one full record attempt, one command:
#
#   fresh-family scan (rotating rng-seed) -> hunt_pipeline (hunt, score, GPU
#   climb, record push on the leaders) -> cycle summary appended to
#   main\cycles.txt
#
# WHY THE RNG-SEED ROTATES: the scan's sampling is deterministic, so the same
# rng-seed re-derives the SAME (mask,val) family at every spot - rerunning it
# is a replay, not a new search. Each family is a 2^34-seed residue class out
# of 2^14 possible per spot, and which one the derivation lands on depends on
# the sample. A fresh rng-seed per cycle = fresh families everywhere = each
# cycle explores search space no earlier cycle could reach. Measured across
# cycles: same spot went 64.06 -> 65.06 purely from family rotation + sweeps.
param(
    # 25k, not 10k: the ledger skips families already hunted, so a fixed window
    # gets progressively picked over - a wider one keeps feeding genuinely new
    # spots. Pass 1 (the variance gate) is nearly free even at ~200k locations,
    # and pass 2's cost is capped by --gate-top regardless of window size, so
    # widening costs almost nothing per cycle. Also doubles as the -MaxDist cap,
    # so results stay within 25k blocks of spawn.
    [int]$Range      = 25000,     # blocks, both axes (X via --range-x)
    # 4s, was 12s. NOT a cut in search depth - a cut in IDLE TIME. This is a
    # wall-clock budget, and the hunt got 10.5x faster (4M -> 41.9M seeds/s
    # measured on this box with the fused kernel now default), so the old 12s
    # bought 48M seeds and 4s now buys ~168M - still 3.5x DEEPER per spot than
    # the setting was ever calibrated for. The freed time goes into -Top below.
    # Dead spots do not even reach this budget: --give-up-after is denominated
    # in SEEDS (20M), so it is hardware-independent and now fires at ~0.5s.
    [int]$Seconds    = 4,         # triage hunt per spot
    # 120, was 40. The scan's pass 2 measured 0.14 s/spot here (it was ~1-3s),
    # so candidate spots are ~10-20x cheaper than when 40 was chosen. The
    # project's own tail fit says a record is driven by the NUMBER of distinct
    # spots checked (~300 for even odds, ~690 for 90%; 121 done), and 66.04 is
    # a hard plateau where hunting one family deeper provably does not help -
    # so breadth is where the new hardware has to be spent, not depth.
    [int]$Top        = 120,
    [int]$Floor      = 64,
    # 220. This was cut to 80 on the reasoning that "ranking does not predict
    # quality" - which was WRONG, and the measurement that caught it is worth
    # keeping. Six metrics failed to predict which spot yields a RECORD; that is
    # not the same as failing to predict whether a spot PRODUCES SEEDS AT ALL,
    # and pass 2 clearly does the latter:
    #     gate-top 220 (emit best 40 of 220) -> ~34% of spots productive
    #     gate-top  80 (emit best 40 of  80) -> ~15% of spots productive
    # Per PRODUCTIVE spot - the thing actually being bought - 220 costs ~33s and
    # 80 costs ~53s, so the "optimization" made the search ~60% less efficient
    # while looking 30% faster. Cycle wall-time is the wrong thing to minimise;
    # productive spots per hour is the objective.
    # (Distance was ruled out as the cause: variance is flat from X=0 to
    # X=100000 - best 31.7/32.3, median 21.9/22.2 - so far spots are not
    # inherently worse.)
    #
    # 600, was 220 - moved UP, which is the safe direction given the above. The
    # lesson from the 220->80 regression was that a bigger gate buys a higher
    # PRODUCTIVE FRACTION (34% at 220 vs 15% at 80); nothing in that measurement
    # suggested 220 was the ceiling, only that 80 was too low. Pass 2 now costs
    # 0.14 s/spot (measured), so 600 candidates cost ~84s where 220 used to cost
    # minutes. If the productive fraction ever drops materially at 600, that is
    # the signal to come back down - measure it, do not assume it.
    [int]$GateTop    = 600,
    # Shift the hunted window away from spawn. Both records and everything
    # found so far live within the original +/-25k box, and the ledger
    # ("family mined") is thinning that box out - by cycle #28, 13-14
    # genuinely new spots/cycle out of 120 offered, the rest already-known.
    # README's own strategy for this: "Repeat at --center-x 40000, then
    # -40000: new windows, new families." Defaults (0,0) reproduce the
    # original origin-centered window exactly - nothing changes for anyone
    # not passing these.
    [int]$CenterX    = 0,
    [int]$CenterZ    = 0,
    [int]$RngSeed    = 0,         # 0 = derive from the clock
    [int]$Repeat     = 1,         # run N cycles back to back, then stop
    # -ForceMask: see hunt_pipeline. A bad DERIVED mask is unrecoverable by
    # val-sweeping, and the derivation missed at both record spots.
    [string]$ForceMask = "",
    # Breadth controls. -NoAnchor stops spending push budget on the known 66.04
    # record family every cycle; -PushTop/-PushSeconds trade dwell per family
    # for number of families pushed. Defaults match hunt_pipeline.
    [switch]$NoAnchor,
    [int]$PushTop     = 3,
    [int]$PushSeconds = 15,
    # -AutoMask: a brand-new mask EVERY cycle, never used before by any run (not in
    # main\masks_used.txt, not in families.csv). Implies -ForceMask per cycle.
    [switch]$AutoMask,
    # -Profile auto|laptop|rental. auto picks by GPU. An explicitly passed
    # -GateTop/-Seconds/-PushTop/-PushSeconds always wins over the profile.
    [string]$Profile = "auto",
    # -ReuseScan: scan ONCE per -Repeat run and hunt that spot list every cycle.
    # The scan ranks LOCATIONS, which do not depend on the seed: across cycles with
    # different rng seeds, 64-91% of the 120 emitted spots were identical, and on the
    # laptop the scan is ~125s of a ~650s 50k cycle. The families stay new because
    # -AutoMask gives every cycle a never-used mask - so reuse needs -AutoMask (or
    # -ForceMask); without one the ledger would just skip the repeated spots.
    [switch]$ReuseScan,
    # -Lines 3,4,5: scan ONLY these hot Z lines, each over X = CenterX +/- RangeX.
    # Line k is centred on chunk row 48.5 + 96.875k (3 rows scanned around it) -
    # NOT the old 97-chunk / 1552-block lattice, which drifts 2 blocks per line off
    # the real band (measured with an exact Java model out to Z = 30M: period
    # 96.875 chunks = 1550 blocks). Lines 3/4/5 are Z ~5426/6976/8526. Any k works,
    # including far lines from the world survey. With an EQUAL share of -GateTop
    # and -Top per line. Why: a 50k --z-all scan put 106 of 120 spots on lines 3/4/5
    # anyway (77 on line 4 alone), and per hunted family those three lines have
    # 2.0% >= 62 cq vs 0.65% on every other line in the ledger. The equal share is
    # because pass 2 over-picks line 4 while line 5 has the better tail
    # (>= 63 cq: 1.6% of families vs 0.6%). Range, not quality, is what the extra
    # X buys: variance is flat out to X = 100000.
    [string]$Lines = "",
    [int]$RangeX = 0,             # X half-width for -Lines (blocks); 0 = -Range
    # -Spots <file.csv with X,Z block columns>: hunt exactly these spots, no scan.
    # For candidates ranked by HEAT (the exact-model tail probability F(X) x G(Z)).
    # Commands are written directly rather than through the scan's pass 2, which
    # only emits spots whose family derivation succeeds and would silently drop
    # hot candidates; the forced-mask triage sweep picks each spot's family
    # instead, so this needs -AutoMask or -ForceMask.
    [string]$Spots = "",
    # -Heat: RETIRED 2026-09-13 (model-ranked heat_spots hunts; replaced by -PhaseSearch). Kept only
    # so an old command line gets a clear message instead of a parameter error.
    [switch]$Heat,
    [string]$HeatLines = "",
    # -Families: old name, now runs -BestFamily (it ranked families by their AVERAGE rate,
    # which missed the record families - the 68.28's ranked 94th).
    [switch]$Families,
    # -BestFamily: THE RECORD SEARCH (2026-09-11). Every spot is searched in the family IT is
    # best in - not a family ranked by an average, and not one family shared by many spots.
    # Spots: heat\best_spots.ps1 (re-measured X x line values, hottest first). Per spot,
    # heat\best_family.ps1 sweeps ALL 1,048,576 20-bit families with the windowed sweep
    # (best AFK chunk within +-3 X / +-2 Z), re-checks the top 8 at 2M seeds, and walks
    # every seed (2^28) of the best ones. Resumable; one cycles.txt line per batch.
    # Measured on 23 spots: the record families rank #1, #1, #3 of 1,048,576 from the spot
    # centre; new 66.61 / 66.17 farms where earlier methods found nothing.
    [switch]$BestFamily,
    [int]$BestFamilyBatch = 10,   # spots per logged cycle
    [string]$BestFamilySpots = "",  # fixed spot list for -BestFamily (default: hottest-first best_spots)
    # -PhaseSearch: the EXACT search (2026-09-12, docs\PHASE_MODEL.txt). Per spot,
    # heat\phase_spots.ps1 runs hotspot_scan --phase-search: every seed of the families in the
    # top 3% by possible chunks, at every AFK chunk within +-5 X / +-4 Z, solved exactly from
    # the phase model. Same batches, spot lists and stop rules as -BestFamily.
    [switch]$PhaseSearch,
    # -GateCount: RECORD MODE for -PhaseSearch. Screen each batch first (0.32 s/spot) and search only
    # spots whose screen reaches this chunk count; the rest are parked in gate_skipped.csv. A record
    # needs 75+ chunks (19,012 = 95% of what 78 can hold), and only 1% of spots ever reach 76.
    # 74 is the measured setting: 3.75% of spots searched, both 76+ spots of a 400-spot sample kept.
    [int]$GateCount = 0,
    [double]$MinHeat = 0,          # optional stop for -BestFamily / -PhaseSearch: hottest spot left below this heat40 (0 = off)
    # Seeds at or above this get hunt_pipeline's wide 28-bit DEEP climb (~90-200 s
    # each on the laptop). See hunt_pipeline -DeepClimbMinCQ and docs\REFERENCE.md "CLIMBS".
    [double]$DeepClimbMinCQ = 65.0,
    # THE Y PHASE (y_phase.ps1): after each cycle, every standing height (feet y -63..-39) on the
    # cycle's best few NEW farms only. Every new farm at or above -YPhaseMinCQ gets one quick -39
    # check (max 200); the -YPhaseTop best by their better end (-39 or floor) get all 25 heights.
    # Each farm once ever, a couple of seconds a cycle; it never changes the hunt or the ranking, it
    # only writes main\y_phase.csv and a short table. 0 = off.
    [int]$YPhaseTop = 5,
    [double]$YPhaseMinCQ = 66.0,
    [switch]$Status              # print progress so far and exit, run nothing
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
# ---- progress, persisted across sessions --------------------------------
# Everything needed to resume already lives on disk: main\cycles.txt is the
# numbered run log and main\families.csv is the ledger of every (mask,val)
# already hunted. So cycles can be run days apart and never repeat work - the
# next number is just "how many cycles have been logged", and the ledger keeps
# skipping families that were already mined in earlier sessions.
# The record to beat was hardcoded at 66.04 - correct as long as that stayed
# the actual best, but the moment a genuinely new record is found (e.g.
# 66.21 at (40776,5411)) and its family isn't mined yet, EVERY cycle that
# re-hunts that still-productive family reports the SAME number again, and a
# hardcoded 66.04 comparison would call it "NEW RECORD" every single time -
# stopping a -Repeat queue on a result that isn't actually new. Read the true
# current best from the ledger instead; 66.04 remains the floor only for a
# fresh checkout with no families.csv yet.
# The records index is read too: the scan history (ledger) can be reset - it was on
# 2026-09-12, archived in main\archive\scan_history_2026-09-12 - but the records are kept,
# and without them an empty ledger would call anything above 66.04 a new record.
function Get-KnownBest {
    $best = 66.04
    if (Test-Path main\families.csv) {
        $top = Import-Csv main\families.csv | Sort-Object { [double]$_.BestCQ } -Descending | Select-Object -First 1
        if ($top -and [double]$top.BestCQ -gt $best) { $best = [double]$top.BestCQ }
    }
    if (Test-Path main\records\index.csv) {
        $top = Import-Csv main\records\index.csv | Sort-Object { [double]$_.CQ } -Descending | Select-Object -First 1
        if ($top -and [double]$top.CQ -gt $best) { $best = [double]$top.CQ }
    }
    return $best
}

function Show-Status {
    $done = 0
    if (Test-Path main\cycles.txt) {
        $done = @(Get-Content main\cycles.txt | Where-Object { $_ -match '^#\d+' }).Count
    }
    $spots = 0; $prod = 0; $best = 0.0; $bestLine = ""
    if (Test-Path main\families.csv) {
        $fam = Import-Csv main\families.csv
        $spots = @($fam | Select-Object -Property SpotX,SpotZ -Unique).Count
        $prod  = @($fam | Where-Object { [double]$_.BestCQ -gt 0 }).Count
        $top   = $fam | Sort-Object { [double]$_.BestCQ } -Descending | Select-Object -First 1
        if ($top) { $best = [double]$top.BestCQ; $bestLine = "($($top.X),$($top.Z))  seed $($top.Seed)" }
    }
    Write-Host "=== RECORD HUNT PROGRESS ===" -ForegroundColor Cyan
    Write-Host ("  cycles completed : {0}" -f $done)
    Write-Host ("  distinct spots   : {0}   ({1} produced seeds)" -f $spots,$prod)
    Write-Host ("  best found       : {0} cq  {1}" -f $best,$bestLine)
    Write-Host ("  record to beat   : {0} cq" -f (Get-KnownBest))
    # Odds, derived from THIS ledger rather than a fixed assumption.
    #
    # The original form hardcoded "300 spots for even odds, 690 for 90%", from
    # an early sample of 92 spots. Two problems showed up once the ledger got
    # large: (a) past 300 spots both subtractions go negative, clamp to zero,
    # and it printed the meaningless "~0 more cycles"; (b) the 1/300 rate is
    # falsified by the ledger itself - at 1606 spots with nothing above the
    # record, a true 1/300 would have produced ~5 hits.
    #
    # So: estimate p from what actually happened. With ZERO spots beating the
    # record in N tries, the standard 95% upper bound is the rule of three,
    # p <= 3/N. That is a BOUND, not a point estimate - the real p may be far
    # smaller - so this reports "at least" figures and says so.
    if ($spots -gt 0 -and $done -gt 0) {
        $perCycle = [math]::Max(1.0, $spots / [double]$done)
        Write-Host ("  spots per cycle  : {0:N1} (measured over {1} cycles)" -f $perCycle,$done) -ForegroundColor DarkGray
        # how many distinct spots have been checked without beating the record
        $pUpper  = 3.0 / [double]$spots          # rule of three, 95% bound
        $n50     = [math]::Ceiling([math]::Log(2.0) / $pUpper)
        $n90     = [math]::Ceiling([math]::Log(10.0) / $pUpper)
        Write-Host ("  observed rate    : 0 spots beat {0} cq in {1} checked -> p <= 1/{2:N0} (95% bound)" `
            -f (Get-KnownBest), $spots, [math]::Round(1.0/$pUpper)) -ForegroundColor DarkGray
        Write-Host ("  odds (optimistic): >= {0:N0} more spots (~{1:N0} cycles) for even money," `
            -f $n50, [math]::Ceiling($n50/$perCycle)) -ForegroundColor DarkGray
        Write-Host ("                     >= {0:N0} more spots (~{1:N0} cycles) for 90%." `
            -f $n90, [math]::Ceiling($n90/$perCycle)) -ForegroundColor DarkGray
        Write-Host ("                     These are LOWER bounds - the true rate is likely worse," ) -ForegroundColor DarkGray
        Write-Host ("                     since {0} spots have already produced nothing better." -f $spots) -ForegroundColor DarkGray
    }
    if (Test-Path main\cycles.txt) {
        Write-Host "`n  recent cycles:" -ForegroundColor Cyan
        Get-Content main\cycles.txt | Where-Object { $_ -match '^#\d+' } | Select-Object -Last 6 | ForEach-Object { Write-Host "    $_" }
    }
}
if ($Status) { Set-Location $root; Show-Status; exit 0 }

if ($Families) {
    # -Families ranked families by their AVERAGE slime rate (heat\family_spots.ps1). The
    # average does not find record families (the 68.28's family ranked 94th by it), so
    # it now runs the per-spot best-family search instead.
    Write-Host "  -Families is now -BestFamily (families ranked by mean missed the record families)" -ForegroundColor Yellow
    $BestFamily = $true
}
if ($PhaseSearch) { $BestFamily = $true }
if ($BestFamily) {
    # the per-spot driver and its results file: phase_spots / phase_search.csv for -PhaseSearch,
    # best_family / best_family.csv otherwise (same SpotBest / BestAt / BestSeed columns)
    $bfDriver = if ($PhaseSearch) { "heat\phase_spots.ps1" } else { "heat\best_family.ps1" }
    $bfOut    = if ($PhaseSearch) { "main\theory\heat\phase_search.csv" } else { "main\theory\heat\best_family.csv" }
    $bfName   = if ($PhaseSearch) { "phase-search" } else { "best-family" }
    # NEW SPOTS ONLY: a spot scanned by any of these is never offered again
    $bfDone   = @($bfOut, "main\theory\heat\phase_search.csv", "main\theory\heat\best_family.csv", "main\theory\heat\phase_validation.csv") | Select-Object -Unique
    # -GateCount parks the spots the screen rules out for a record. They never reach phase_search.csv,
    # so without this line they are picked again every cycle and the run spins on 0-spot cycles.
    if ($GateCount -gt 0) { $bfDone += "main\theory\heat\gate_skipped.csv" }
    for ($rep = 1; $rep -le $Repeat; $rep++) {
        if (Test-Path "main\STOP_WR") { Write-Host "STOP_WR present - stopping" -ForegroundColor Yellow; break }
        $t0 = Get-Date; $kb = Get-KnownBest     # before the batch: its own finds go into the ledger
        $nBefore = if (Test-Path $bfOut) { @(Import-Csv $bfOut).Count } else { 0 }   # the batch's rows are the ones after these
        $n66 = if (Test-Path main\records\over66.csv) { @(Import-Csv main\records\over66.csv).Count } else { 0 }
        # -BestFamilySpots <file>: a fixed list (e.g. main\strat_spots.csv) instead of the
        # hottest-first list; either way spots already in best_family.csv are skipped.
        $spotFile = if ($BestFamilySpots) { $BestFamilySpots } else { & (Join-Path $root "heat\best_spots.ps1") -Count 500 -Skip ($bfDone -join ',') | Out-Null; "main\best_spots.csv" }
        $doneBF = @{}; foreach ($df in $bfDone) { if (Test-Path $df) { foreach ($d in (Import-Csv $df)) { $doneBF["$($d.X),$($d.Z)"] = 1 } } }
        $next = @(Import-Csv $spotFile | Where-Object { -not $doneBF.ContainsKey("$([int]$_.X),$([int]$_.Z)") } | Select-Object -First $BestFamilyBatch)
        if ($next.Count -eq 0) { Write-Host "  -BestFamily: no spots left in best_spots" -ForegroundColor Yellow; break }
        if ($MinHeat -gt 0 -and [double]$next[0].Heat40 -lt $MinHeat) { Write-Host ("  -BestFamily: hottest spot left is heat {0} < -MinHeat {1}" -f $next[0].Heat40, $MinHeat) -ForegroundColor Yellow; break }
        $cycleNo = 1 + $(if (Test-Path main\cycles.txt) { @(Get-Content main\cycles.txt | Where-Object { $_ -match '^#\d+' }).Count } else { 0 })
        Write-Host ("=== CYCLE #{0} {1} ({2} of {3}): {4} spots, heat {5}..{6} ===" -f $cycleNo, $bfName.ToUpper(), $rep, $Repeat, $next.Count, $next[0].Heat40, $next[-1].Heat40) -ForegroundColor Cyan
        $gate = @{}; if ($PhaseSearch -and $GateCount -gt 0) { $gate['GateCount'] = $GateCount }
        & (Join-Path $root $bfDriver) -SpotFile $spotFile -Spots $BestFamilyBatch @gate
        $rows = @(if (Test-Path $bfOut) { Import-Csv $bfOut | Select-Object -Skip $nBefore })
        $bfTop = $rows | Sort-Object { [double]$_.SpotBest } -Descending | Select-Object -First 1
        $new66 = $(if (Test-Path main\records\over66.csv) { @(Import-Csv main\records\over66.csv).Count } else { 0 }) - $n66
        $line = "#{0}  {1}  {10}  {2} spots heat {3}..{4}  best {5} cq  {6}  seed {7}  new 66+: {8}  {9}s" -f $cycleNo, (Get-Date -Format 'yyyy-MM-dd HH:mm'),
            $rows.Count, $next[0].Heat40, $next[-1].Heat40, $(if ($bfTop) { $bfTop.SpotBest } else { 0 }), $(if ($bfTop) { $bfTop.BestAt } else { "" }), $(if ($bfTop) { $bfTop.BestSeed } else { "" }), $new66, [int]((Get-Date) - $t0).TotalSeconds, $bfName
        # A gated batch that searched nothing is not a cycle - it is screening. Logging those as numbered
        # cycles would bury the run history (a full sweep of the list is ~85 of them). They go to a
        # screening log instead, and the cycle number is left for batches that actually searched a spot.
        if ($rows.Count -eq 0 -and $GateCount -gt 0) {
            Add-Content -Path main\logs\gate.log -Value ("{0}  screened {1} spots heat {2}..{3}, none reached the gate  {4}s" -f `
                (Get-Date -Format 'yyyy-MM-dd HH:mm'), $next.Count, $next[0].Heat40, $next[-1].Heat40, [int]((Get-Date) - $t0).TotalSeconds) -Encoding UTF8
        } else {
            Add-Content -Path main\cycles.txt -Value $line -Encoding UTF8
            Write-Host $line -ForegroundColor Green
        }
        # Y phase on this batch's new 66+ farms (the rows over66.csv gained during it)
        if ($YPhaseTop -gt 0 -and $new66 -gt 0) {
            & (Join-Path $root "y_phase.ps1") -In main\records\over66.csv -Skip $n66 -Top $YPhaseTop -MinCQ $YPhaseMinCQ -Label "cycle $cycleNo"
        }
        if ($bfTop -and [double]$bfTop.SpotBest -gt $kb) {
            Write-Host ("NEW RECORD {0} cq" -f $bfTop.SpotBest) -ForegroundColor Magenta
            Add-Content -Path main\cycles.txt -Value ("   NEW RECORD {0} cq  {1}  seed {2}" -f $bfTop.SpotBest, $bfTop.BestAt, $bfTop.BestSeed) -Encoding UTF8
            # -PhaseSearch keeps going (it is archived, logged and ledgered); -BestFamily stops as before
            if (-not $PhaseSearch) { break }
        }
    }
    exit 0
}

# fail BEFORE the 5-minute scan if the pipeline script won't parse - a syntax
# slip already burned one full cycle silently
$perr = $null
[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root "hunt_pipeline.ps1"), [ref]$null, [ref]$perr) | Out-Null
if ($perr.Count) { $perr | ForEach-Object { Write-Host $_.Message -ForegroundColor Red }; exit 1 }

$baseSeed = $RngSeed
# The actual current best, not a hardcoded 66.04 - see Get-KnownBest above.
# Updated in-loop on a genuine improvement so a -Repeat run doesn't also stop
# on cycle 2 re-reporting the SAME new number cycle 1 just found.
$knownBest = Get-KnownBest
# ---- HARDWARE PROFILE -------------------------------------------------------
# Every wall-clock value in this project was calibrated on ONE box, and a 13-41x
# swing between GPUs has already happened here. The objective is PRODUCTIVE SPOTS
# PER HOUR (see -GateTop above), and pass 2's cost per spot differs ~6.6x between
# the two machines this has run on:
#   rental  RTX PRO 6000, 188 SMs, 96 GB : pass 2 ~0.14 s/spot, hunt ~55M seeds/s
#   laptop  RTX 4050,       20 SMs,  6 GB : pass 2 ~0.93 s/spot, hunt  ~7M seeds/s
# gate-top: 600 was tuned on the rental (600 spots ~84s). On the laptop the same
#   600 costs ~9 min, and 220 - this file's own previously measured sweet spot,
#   34% productive vs 15% at 80 - is the better rate there.
# -Seconds: triage was originally calibrated at ~48M seeds/spot. 4s buys ~168M on
#   the rental but only ~28M on the laptop, so the laptop gets 6s (~42M).
# These are STARTING POINTS from measured costs, not a measured optimum - re-bench
# on any new GPU (hotspot_scan --bench) and override with explicit parameters.
$gpuName = ""; $gpuMem = 0
try {
    $q = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    if ($q) { $parts = $q -split ','; $gpuName = $parts[0].Trim(); $gpuMem = [int]($parts[1].Trim()) }
} catch {}
if ($Profile -eq "auto") {
    $Profile = if ($gpuMem -ge 40000 -or $gpuName -match 'PRO 6000|RTX 6000|H100|A100|H200|B200') { "rental" } else { "laptop" }
}
$prof = if ($Profile -eq "rental") { @{GateTop=600; Seconds=4; PushTop=8; PushSeconds=15} }
        else                       { @{GateTop=220; Seconds=6; PushTop=6; PushSeconds=12} }
foreach ($k in $prof.Keys) {
    if (-not $PSBoundParameters.ContainsKey($k)) { Set-Variable -Name $k -Value $prof[$k] }
}
Write-Host ("hardware profile: {0}  ({1}, {2} MiB)  gate-top {3}  seconds {4}  push {5} x {6}s" -f `
    $Profile,$gpuName,$gpuMem,$GateTop,$Seconds,$PushTop,$PushSeconds) -ForegroundColor DarkCyan
if ($AutoMask -and $ForceMask) { Write-Host "  -AutoMask overrides -ForceMask (a new mask every cycle)" -ForegroundColor Yellow }
if ($ReuseScan -and -not ($AutoMask -or $ForceMask)) {
    Write-Host "  -ReuseScan ignored: without -AutoMask/-ForceMask every reused spot is an already-hunted family" -ForegroundColor Yellow
    $ReuseScan = $false
}
$scanCmds = $null
$spotList = @()
New-Item -ItemType Directory -Force -Path "main\logs\scans" | Out-Null
function Read-SpotList($path) {
    # snap to chunk corners, the same block coordinates the scan emits
    # each element parenthesised: in PowerShell "a * 16, b * 16" parses as a * (16, b) * 16
    $l = @(Import-Csv $path | ForEach-Object {
        $sx = [int]([math]::Floor([double]$_.X / 16) * 16); $sz = [int]([math]::Floor([double]$_.Z / 16) * 16)
        ,@($sx, $sz) })
    if ($l.Count -eq 0 -or @($l | Where-Object { $_.Count -ne 2 }).Count) { throw "no usable X,Z rows in $path" }
    return ,$l
}
if ($Heat) {
    # RETIRED 2026-09-13. -Heat hunted model-ranked spots (heat\heat_spots.ps1, heat_cache.csv) with
    # triage sweeps; the exact phase search on the MEASURED spot list replaced it (-PhaseSearch), and its
    # heat cache lacked most measured spots (~1 h CPU to rebuild). heat_spots.ps1 / record_odds.ps1 are in heat\old.
    Write-Host "-Heat is retired (2026-09-13): use  record_cycle.ps1 -PhaseSearch  (the exact search on the measured spot list)." -ForegroundColor Yellow
    exit 1
} elseif ($Spots) {
    if (-not ($AutoMask -or $ForceMask)) { throw "-Spots needs -AutoMask or -ForceMask (the triage sweep picks each spot's family)" }
    $spotList = Read-SpotList $Spots
    if (-not $PSBoundParameters.ContainsKey('Top')) { $Top = $spotList.Count }
    $ReuseScan = $true   # a fixed list: every cycle hunts it again with a new mask
}
$lineKs = @()
if ($Lines) {
    $lineKs = @($Lines -split ',' | Where-Object { $_.Trim() } | ForEach-Object { [int]$_.Trim() })
    $lineRX = if ($RangeX -gt 0) { $RangeX } else { $Range }
    Write-Host ("  -Lines {0}: X {1}..{2} on each, {3} spots per line" -f ($lineKs -join ','),($CenterX-$lineRX),($CenterX+$lineRX),[math]::Ceiling($Top/$lineKs.Count)) -ForegroundColor DarkCyan
}

for ($rep = 1; $rep -le $Repeat; $rep++) {
# Cycle number continues from the log, so runs days apart keep counting up
# instead of restarting at 1.
$cycleNo = 1
if (Test-Path main\cycles.txt) {
    $cycleNo = 1 + @(Get-Content main\cycles.txt | Where-Object { $_ -match '^#\d+' }).Count
}
# Fresh rng-seed per cycle even inside a -Repeat run: reusing one replays the
# same families and the cycle finds nothing new.
$RngSeed = if ($baseSeed -ne 0) { $baseSeed + $rep - 1 }
           else { ([int](Get-Date -UFormat %s) + $rep * 7919) -band 0x7FFFFFFF }
$name = "cyc{0:x}" -f $RngSeed
if ($AutoMask) {
    # A mask that has NEVER been used by any run: not in main\masks_used.txt and
    # not in families.csv. Bits 0, 1 and 12 are kept - the README measured them
    # selected 15/15 times across real derivations - and the other 11 of 14 are
    # drawn from the rest of the 20-bit window. Recorded BEFORE the hunt, so a
    # cycle that crashes still counts its mask as spent and it is never reissued.
    $usedMasks = @{}
    $muPath = "main\masks_used.txt"
    if (Test-Path $muPath) { foreach ($m in (Get-Content $muPath)) { if ($m.Trim()) { $usedMasks[$m.Trim().ToUpper()] = 1 } } }
    if (Test-Path "main\families.csv") { foreach ($f in (Import-Csv "main\families.csv")) { $usedMasks[$f.Mask.ToUpper()] = 1 } }
    $mrng = New-Object System.Random ($RngSeed -bxor 0x5A5A5A5A)
    $pool = @(2,3,4,5,6,7,8,9,10,11,13,14,15,16,17,18,19)
    $ForceMask = $null
    for ($try = 0; $try -lt 5000 -and -not $ForceMask; $try++) {
        $pick = $pool | Sort-Object { $mrng.Next() } | Select-Object -First 11
        $mv = 0; foreach ($b in (@(0,1,12) + $pick)) { $mv = $mv -bor (1 -shl $b) }
        $hx = "0x{0:X}" -f $mv
        if (-not $usedMasks.ContainsKey($hx.ToUpper())) { $ForceMask = $hx }
    }
    if (-not $ForceMask) { throw "AutoMask: no unused mask found in 5000 draws" }
    Add-Content -Path $muPath -Value $ForceMask -Encoding ascii
    Write-Host ("  auto-mask this cycle: {0} (never used before; recorded in {1})" -f $ForceMask,$muPath) -ForegroundColor DarkCyan
}
Write-Host ("=== CYCLE #{0}{1}  rng 0x{2:X}  name {3} ===" -f `
    $cycleNo, $(if ($Repeat -gt 1) { " ($rep of $Repeat)" } else { "" }), $RngSeed, $name) -ForegroundColor Cyan

$sw = [Diagnostics.Stopwatch]::StartNew()
# --score-t 70, not 68: the count x packing frontier peaks at exactly 70 chunks
# (95.9% @68c, 94.9% @69c, 94.3% @70c, 91.4% @71c - the record IS the peak), so
# 70 is the only count a record can realistically land on. At score-t 70 the
# scan's pWin bar becomes 66.04/70 = 94.34% - the true winning threshold -
# where score-t 68 demanded an unreachable 97.1% and zeroed pWin everywhere.
if ($ReuseScan -and $scanCmds) {
    Write-Host ("  -ReuseScan: hunting {0} again with this cycle's new mask" -f $scanCmds) -ForegroundColor DarkCyan
} elseif ($spotList.Count -gt 0) {
    $scanCmds = "main\commands\commands_{0}.csv" -f $name
    $cmds = foreach ($sp in $spotList) {
        "slime_gpu.exe --seed-count 0 --center-x {0} --center-z {1} --m-chunks 24 --fix-mask 0xFFFFF --fix-val 0x0 --record-floor 70 --seeds-floor 70 --report-every 50000000 --give-up-after 20000000 --give-up-hits 10 --give-up-floor 64 --seeds-out main/seeds/{0}_{1}.csv" -f $sp[0],$sp[1]
    }
    Set-Content -Path $scanCmds -Value $cmds -Encoding ascii
    Write-Host ("  -Spots: {0} spots from {1}, no scan (family picked by the forced-mask triage)" -f $spotList.Count,$Spots) -ForegroundColor DarkCyan
} elseif ($lineKs.Count -gt 0) {
    # One scan per line, then interleave rank 1 of every line, rank 2, ... so each
    # line gets the same number of spots and the best of each line goes first.
    $perGate = [int][math]::Ceiling($GateTop / $lineKs.Count)
    $perTop  = [int][math]::Ceiling($Top / $lineKs.Count)
    $perLine = @()
    foreach ($k in $lineKs) {
        $ln = "{0}L{1}" -f $name,$k
        $zc = [math]::Floor(48.5 + 96.875 * $k)
        .\hotspot_scan.exe --scan --center-x $CenterX --center-z 0 --range $lineRX --range-x $lineRX `
            --z-only ("{0},{1},{2}" -f (16*($zc-1)),(16*$zc),(16*($zc+1))) `
            --rng-seed $RngSeed --var-min 26 --gate-top $perGate --score-t 70 --bit-window 20 `
            --emit-top $perTop --name $ln --out ("main\work\lines_{0}.csv" -f $ln) *> ("main\logs\scans\scan_{0}_log.txt" -f $ln)
        if ($LASTEXITCODE -ne 0) { Write-Host "scan failed - see main\logs\scans\scan_${ln}_log.txt" -ForegroundColor Red; exit 1 }
        $perLine += ,@(Get-Content ("main\work\lines_{0}.csv" -f $ln) | Where-Object { $_.Trim() })
        Remove-Item ("main\work\lines_{0}.csv" -f $ln) -ErrorAction SilentlyContinue   # merged below; only the merged list is kept
        Write-Host ("  line {0} (Z {1}..{2}): {3} spots" -f $k,(16*($zc-1)),(16*($zc+1)),$perLine[-1].Count) -ForegroundColor DarkCyan
    }
    $merged = for ($r = 0; $r -lt $perTop; $r++) { foreach ($pl in $perLine) { if ($r -lt $pl.Count) { $pl[$r] } } }
    $scanCmds = "main\commands\commands_{0}.csv" -f $name
    Set-Content -Path $scanCmds -Value $merged -Encoding ascii
} else {
.\hotspot_scan.exe --scan --center-x $CenterX --center-z $CenterZ --range $Range --range-x $Range --z-all `
    --rng-seed $RngSeed --var-min 26 --gate-top $GateTop --score-t 70 --bit-window 20 `
    --emit-top $Top --name $name *> ("main\logs\scans\scan_{0}_log.txt" -f $name)
if ($LASTEXITCODE -ne 0) { Write-Host "scan failed - see main\logs\scans\scan_${name}_log.txt" -ForegroundColor Red; exit 1 }
$scanCmds = "main\commands\commands_{0}.csv" -f $name
}
$scanS = [int]$sw.Elapsed.TotalSeconds

# -MaxDist is a TRUE distance-from-spawn cap, not a distance-from-scan-center
# cap (hunt_pipeline.ps1 measures every spot from the real origin) - so an
# offset center needs its own distance added on top of $Range, or every spot
# in a shifted window gets filtered out as "too far" even though the window
# itself is exactly as wide as the origin-centered case always was.
$centerDist = [int][math]::Sqrt([double]$CenterX*[double]$CenterX + [double]$CenterZ*[double]$CenterZ)
# -Record $knownBest: hunt_pipeline.ps1 has its OWN "*** NEW RECORD ***"
# banner in main\pipeline.txt (its per-cycle detail report), separate from
# this script's cycles.txt line and $isRec/$knownBest logic below. It
# defaults to a hardcoded 66.04 same as this script's OLD bug did - without
# passing $knownBest through, pipeline.txt would falsely announce "NEW
# RECORD" for anything >66.04 even when 66.21 is already the known best.
# -MaxDist covers the scan's full SQUARE, not its inscribed circle. The scan
# window is +-Range on each axis, but -MaxDist is a true-distance CIRCLE, so
# everything in the square's corners was scanned, ranked and paid for - then
# discarded. Geometrically 1 - pi/4 = 21.5% of candidates; measured at 10k it
# was 28 of 120 (23%). The diagonal keeps them. Trade: -Range 10000 now means
# spots up to ~14,142 blocks out, not a strict 10k circle.
$maxDist = $centerDist + [int][math]::Ceiling($Range * [math]::Sqrt(2))
if ($spotList.Count -gt 0) {
    $maxDist = [int](($spotList | ForEach-Object { [math]::Sqrt([double]$_[0]*$_[0] + [double]$_[1]*$_[1]) } | Measure-Object -Maximum).Maximum) + 64
}
if ($lineKs.Count -gt 0) {
    # Line mode: the window is a thin strip per line, so the farthest corner is
    # (|CenterX| + RangeX, farthest line's Z), plus a chunk of slack.
    $zFar = ($lineKs | ForEach-Object { [math]::Abs((48.5 + 96.875*$_) * 16) } | Measure-Object -Maximum).Maximum + 40
    $xFar = [math]::Abs($CenterX) + $lineRX
    $maxDist = [int][math]::Ceiling([math]::Sqrt([double]$xFar*$xFar + [double]$zFar*$zFar)) + 16
}
.\hunt_pipeline.ps1 -Commands $scanCmds `
    -Seconds $Seconds -Top $Top -Floor $Floor -MaxDist $maxDist -Record $knownBest -ForceMask $ForceMask -PushTop $PushTop -PushSeconds $PushSeconds -NoAnchor:$NoAnchor -DeepClimbMinCQ $DeepClimbMinCQ -NoClimb:$Families
$sw.Stop()

# cycle ledger - numbered, one line per cycle, so progress is legible across
# sessions run days apart. Show-Status counts these lines for the next number.
$rowsAll = Import-Csv main\pipeline.csv
# Only rows that found seeds THIS cycle. hunt_pipeline also emits a row for
# every family the ledger SKIPS as already mined (Seeds=0), carrying that
# family's HISTORICAL best - so taking the max over all rows reported the
# ledger's all-time 65.06 as this cycle's result, every cycle, regardless of
# what was actually found. Measured on one cycle: 52 of 57 rows were Seeds=0,
# the stale max was 65.06, the real new-find max was 60.14. A stale row can
# never be a new record, so this is correct for record detection too.
$newRows = @($rowsAll | Where-Object { [int]$_.Seeds -gt 0 })
$best = if ($newRows.Count) { $newRows | Sort-Object { [double]$_.CQ } -Descending | Select-Object -First 1 }
        else { [pscustomobject]@{CQ=0; X=0; Z=0; Seed=0; Eff=0; Chunks=0} }
$isRec = ([double]$best.CQ -gt $knownBest)
if ($isRec) { $knownBest = [double]$best.CQ }
# THE HEADLINE NUMBER LIES BY OMISSION. The anchor family is pushed every cycle
# by design, and 66.04 is a hard plateau there - so "best 66.04" prints on
# almost every cycle whether or not anything was discovered, and a mined family
# carried in from the ledger prints it even when that family was never hunted.
# Reading the log, it looks like every cycle finds the record. It does not.
# So also report the best result from ANY OTHER spot, which is the number that
# actually moves when the search makes progress.
# Filter on the RESULT POSITION, not the spot. Filtering by spot does not work:
# the 66.04 plateau is reached from several nearby spots (the ledger carries it
# under SpotX 3696 as well as 3680), so a spot-based filter lets it straight
# through - which it did on the first attempt here. The plateau is one specific
# LAYOUT, so exclude by the layout's position instead.
#
# List every hard plateau found so far, not just the first - each keeps
# getting pushed every cycle until its family is mined (Times >= 2 with no
# improvement), so an un-updated list makes a KNOWN, already-logged plateau
# look like fresh progress the moment a second one joins it.
$knownPlateaus = @(
    @{X=3680;  Z=6989},   # the original 66.04 record
    @{X=40776; Z=5411}    # 66.21, found 2026-08-01 after widening -Range to 50000
)
# $newRows, not $rowsAll: same stale-ledger bug as $best above - skipped
# families carry Seeds=0 rows with their HISTORICAL best, so this printed the
# ledger's all-time 65.06 as "best-elsewhere" on every cycle.
$nonAnchor = $newRows |
    Where-Object { $row = $_; -not ($knownPlateaus | Where-Object { $_.X -eq [int]$row.X -and $_.Z -eq [int]$row.Z }) } |
    Sort-Object { [double]$_.CQ } -Descending | Select-Object -First 1
$naTxt = if ($nonAnchor) { "  best-elsewhere {0} cq ({1},{2})" -f $nonAnchor.CQ,$nonAnchor.X,$nonAnchor.Z }
         else { "  best-elsewhere none" }
$line = ("#{0}  {1}  rng 0x{2:X}  best {3} cq  ({4},{5})  seed {6}  {7}s{8}{9}" -f `
    $cycleNo,(Get-Date -Format 'yyyy-MM-dd HH:mm'),$RngSeed,$best.CQ,$best.X,$best.Z,$best.Seed,
    [int]$sw.Elapsed.TotalSeconds, $naTxt, $(if ($isRec) { "  *** NEW RECORD ***" } else { "" }))
Add-Content -Path main\cycles.txt -Value $line -Encoding UTF8
Write-Host "`n$line" -ForegroundColor $(if ($isRec) { "Magenta" } else { "Green" })
# Y phase on this cycle's new farms only ($newRows: Seeds > 0 - not the ledger's carried-over bests)
if ($YPhaseTop -gt 0 -and $newRows.Count) {
    $yIn = Join-Path $root "main\work\y_phase_cycle.csv"
    $newRows | Export-Csv -Path $yIn -NoTypeInformation
    & (Join-Path $root "y_phase.ps1") -In $yIn -Top $YPhaseTop -MinCQ $YPhaseMinCQ -Label "cycle $cycleNo"
    Remove-Item $yIn -ErrorAction SilentlyContinue
}
if ($isRec) {
    Write-Host ("*** NEW RECORD {0} cq  /tp {1} ~ {2}  seed {3} ***" -f $best.CQ,$best.X,$best.Z,$best.Seed) -ForegroundColor Magenta
    break   # stop the repeat loop; a record is worth looking at before continuing
}
}   # end repeat loop
Show-Status
