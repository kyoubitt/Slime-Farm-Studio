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
    [switch]$Status               # print progress so far and exit, run nothing
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
function Get-KnownBest {
    if (Test-Path main\families.csv) {
        $top = Import-Csv main\families.csv | Sort-Object { [double]$_.BestCQ } -Descending | Select-Object -First 1
        if ($top -and [double]$top.BestCQ -gt 66.04) { return [double]$top.BestCQ }
    }
    return 66.04
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

# fail BEFORE the 5-minute scan if the pipeline script won't parse - a syntax
# slip already burned one full cycle silently
$perr = $null
[System.Management.Automation.Language.Parser]::ParseFile("$root\hunt_pipeline.ps1", [ref]$null, [ref]$perr) | Out-Null
if ($perr.Count) { $perr | ForEach-Object { Write-Host $_.Message -ForegroundColor Red }; exit 1 }

$baseSeed = $RngSeed
# The actual current best, not a hardcoded 66.04 - see Get-KnownBest above.
# Updated in-loop on a genuine improvement so a -Repeat run doesn't also stop
# on cycle 2 re-reporting the SAME new number cycle 1 just found.
$knownBest = Get-KnownBest
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
Write-Host ("=== CYCLE #{0}{1}  rng 0x{2:X}  name {3} ===" -f `
    $cycleNo, $(if ($Repeat -gt 1) { " ($rep of $Repeat)" } else { "" }), $RngSeed, $name) -ForegroundColor Cyan

$sw = [Diagnostics.Stopwatch]::StartNew()
# --score-t 70, not 68: the count x packing frontier peaks at exactly 70 chunks
# (95.9% @68c, 94.9% @69c, 94.3% @70c, 91.4% @71c - the record IS the peak), so
# 70 is the only count a record can realistically land on. At score-t 70 the
# scan's pWin bar becomes 66.04/70 = 94.34% - the true winning threshold -
# where score-t 68 demanded an unreachable 97.1% and zeroed pWin everywhere.
.\hotspot_scan.exe --scan --center-x $CenterX --center-z $CenterZ --range $Range --range-x $Range --z-all `
    --rng-seed $RngSeed --var-min 26 --gate-top $GateTop --score-t 70 --bit-window 20 `
    --emit-top $Top --name $name *> ("main\scan_{0}_log.txt" -f $name)
if ($LASTEXITCODE -ne 0) { Write-Host "scan failed - see main\scan_${name}_log.txt" -ForegroundColor Red; exit 1 }
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
.\hunt_pipeline.ps1 -Commands ("main\commands\commands_{0}.csv" -f $name) `
    -Seconds $Seconds -Top $Top -Floor $Floor -MaxDist ($centerDist + $Range) -Record $knownBest
$sw.Stop()

# cycle ledger - numbered, one line per cycle, so progress is legible across
# sessions run days apart. Show-Status counts these lines for the next number.
$rowsAll = Import-Csv main\pipeline.csv
$best = $rowsAll | Sort-Object { [double]$_.CQ } -Descending | Select-Object -First 1
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
$nonAnchor = $rowsAll |
    Where-Object { $row = $_; -not ($knownPlateaus | Where-Object { $_.X -eq [int]$row.X -and $_.Z -eq [int]$row.Z }) } |
    Sort-Object { [double]$_.CQ } -Descending | Select-Object -First 1
$naTxt = if ($nonAnchor) { "  best-elsewhere {0} cq ({1},{2})" -f $nonAnchor.CQ,$nonAnchor.X,$nonAnchor.Z }
         else { "  best-elsewhere none" }
$line = ("#{0}  {1}  rng 0x{2:X}  best {3} cq  ({4},{5})  seed {6}  {7}s{8}{9}" -f `
    $cycleNo,(Get-Date -Format 'yyyy-MM-dd HH:mm'),$RngSeed,$best.CQ,$best.X,$best.Z,$best.Seed,
    [int]$sw.Elapsed.TotalSeconds, $naTxt, $(if ($isRec) { "  *** NEW RECORD ***" } else { "" }))
Add-Content -Path main\cycles.txt -Value $line -Encoding UTF8
Write-Host "`n$line" -ForegroundColor $(if ($isRec) { "Magenta" } else { "Green" })
if ($isRec) {
    Write-Host ("*** NEW RECORD {0} cq  /tp {1} ~ {2}  seed {3} ***" -f $best.CQ,$best.X,$best.Z,$best.Seed) -ForegroundColor Magenta
    break   # stop the repeat loop; a record is worth looking at before continuing
}
}   # end repeat loop
Show-Status
