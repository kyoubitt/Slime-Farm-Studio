# hunt_pipeline.ps1 - the whole loop in one command.
#
#   scan candidates -> hunt each briefly -> score in REAL cq -> ranked table
#
# Replaces the manual four-step shuffle (run scan, copy commands, run hunts,
# remember to score) with one invocation. Nothing here is new capability - it is
# the same three tools - but closing the seam changes what can be RANKED.
#
# WHY IT RANKS ON cq AND NOT ON SEED COUNT
# -----------------------------------------------------------------------------
# The obvious cheap key is "how many seeds did this spot write in N seconds",
# and it is wrong. Measured directly: (-1008,-8528) wrote the most seeds and is
# hard-capped at ~90% packing, so 71 chunks only reached 64.06 cq. Meanwhile
# (-1008,6976) wrote fewer seeds but packs at 93.5%, within a point of the
# 94.3% the record needs. Chunk count is cheap; PACKING is the scarce thing, and
# it is what decides whether a spot can ever produce a record. Seed count cannot
# see packing at all. Scoring inline costs seconds and ranks on the real answer.
#
# WHY THE HUNTS ARE SHORT
# -----------------------------------------------------------------------------
# Long hunts at one spot do not help: a spot's packing ceiling caps its cq no
# matter how many seeds are drawn. A 90%-packing family cannot reach 66 cq at
# any duration. Time is better spent covering MORE spots and MORE families than
# draining one. Hence: short hunt, score, move on.
param(
    [string]$Commands = "",          # default: newest main\commands\commands_*.csv
    [int]$Seconds     = 20,          # hunt seconds per spot
    [int]$Top         = 20,          # spots to try
    [int]$Floor       = 64,          # seeds-floor for the hunt (0 = leave as the scan wrote it)
    [int]$Radius      = 6,           # slime_refine search radius, chunks
    [double]$Record   = 66.04,       # bar for the NEW RECORD banner
    [switch]$NoImages,               # skip PNGs entirely
    # Only worth a picture above this. Scoring runs image-free and the PNG is
    # regenerated for the single best seed if it clears this bar.
    [double]$ImageMinCQ = 65.0,
    [switch]$NoClimb,                # skip the high-bit sweep of each spot's best seed
    # Only sweep a seed already in contention. The sweep is ~5s per productive
    # spot and reliably lifts a seed ~1-4 cq, but measured gains land at
    # 56.71->60.71, 59.34->60.51, 58.69->61.11 - real, and all far below the
    # ~65 needed to matter. Lifting a 57 to a 60 does not advance a record hunt,
    # it just costs 5s. The ledger still records the spot's unswept best, so
    # nothing is lost except time on seeds that cannot win.
    [double]$ClimbMinCQ = 63.0,
    # DEEP CLIMB bar: seeds at or above this also get the wide 28-bit climb
    # (bits 20-47, ~90-200 s on the laptop). ~2.2 below the 67.24 record: the
    # standard climb adds at most ~2.1 and the deep one ~0.8 on top, so a seed
    # much below this cannot reach the record. About one seed per heat cycle.
    [double]$DeepClimbMinCQ = 65.0,
    # RECORD PUSH: after the ranked table, the top -PushTop spots get a second
    # hunt at floor -PushFloor for -PushSeconds each. Learned from run 2: the
    # leaders keep producing when revisited (64.06 -> 65.06 came from exactly
    # this). NO early abort here - push-floor seeds are rare by design, so
    # silence at 5s is expected, not death.
    #
    # WHY THE PUSH FLOOR IS EXACTLY 70. Best packing achieved at each chunk
    # count, across every seed scored (hundreds, many spots and families):
    #     68c 95.9% -> 65.2      70c 94.3% -> 66.0  <- the record, ON the peak
    #     69c 94.9% -> 65.5      71c 91.4% -> 64.9
    #                            72c 90.4% -> 65.1
    # Packing falls MONOTONICALLY as count rises, and count x packing peaks at
    # exactly 70 chunks - the record sits on the optimum of that frontier, not
    # on a lucky outlier. So 64-69c layouts can NEVER win (their frontier tops
    # out below 66.04) and 71c+ needs packing nobody has produced at that
    # count. A floor-66 push fills the seed file with layouts that are provably
    # useless for a record; floor 70 spends the entire budget drawing samples
    # at the one frontier cell a record can occupy (70c at >=94.4%), while
    # still admitting the 71c-at->=93.2% long shot since floor = minimum.
    #
    # The TRIAGE floor stays 64 on purpose: triage is a discriminator, not a
    # collector - at floor 70 every spot ties at 0 seeds in 12s and the ranking
    # carries no information (floor 64 spreads 26/24/24 vs 10 vs 0, measured).
    # Floor 69, not 70: the floor is a MINIMUM, so 69 is a strict superset -
    # every 70c/71c/72c seed floor 70 would have caught still comes through,
    # plus the 69c ones, and scoring costs 0.02s/seed so the extra is free.
    # Measured at the anchor: 15 seeds/3min at floor 69 vs ~12 at floor 70,
    # and the floor-69 run turned up a fourth independent 66.04 seed. Refine
    # then picks each seed's best position regardless of count, so nothing is
    # lost by admitting lower-count seeds - a 69c seed whose best position is
    # 70c is scored as 70c.
    # 69, decided by measured gaps - NOT by the theoretical limit. 67c is
    # mathematically capable (67 x 100% > 66.04) but the gap between what it
    # NEEDS and what has ever been observed is what matters:
    #     67c  best 96.0%  need 98.57%  gap 2.57
    #     68c  best 95.9%  need 97.12%  gap 1.22
    #     69c  best 94.9%  need 95.71%  gap 0.81
    #     70c  best 94.3%  need 94.34%  gap 0.04   <- the only realistic target
    # Packing falls as count rises, so a low count needs packing that has never
    # been produced AT that count. (99.4% packing has been seen - at 62 chunks,
    # where the requirement is an impossible 106.5%. High packing at low counts
    # proves nothing about high packing at 67.) Below 69 the extra seeds are
    # layouts with gaps 2-3x worse than 70c, so they dilute rather than help.
    [int]$PushTop     = 3,
    [int]$PushFloor   = 69,
    # RICH-FAMILY EXHAUST (2026-09-11; replaces the push when on). Record farms come
    # from rare "rich" 20-bit families: at the 68.28 / 67.32 / 67.24 / 67.22 spots the
    # record's family had 29k-47k hits >=64 in 20M seeds while 48 other top-ranked
    # families had ~0. Triage samples a 14-bit family (64 of these 20-bit families at
    # once), so its hits pile up in the rich one - but it only ever tests ~0.25% of it.
    # This stage reads which 20-bit family the spot's triage hits came from and walks
    # all 2^28 of its seeds (slime_gpu --enumerate --fix-mask 0xFFFFF, ~38 s laptop,
    # ~5 s PRO 6000). Checked: exhausting the 68.28's family re-finds 68.28 and adds
    # 67.28, 67.28, 66.73, 66.56 at that spot. Climbs are unnecessary (every high-bit
    # variant is enumerated). Ledgered as 0xFFFFF|val@x,z.
    [int]$RichTop     = 6,          # spots per cycle, richest triage families first
    [int]$RichSeconds = 45,         # per family (2^28 seeds)
    [int]$RichMinHits = 3,          # triage hits in one 20-bit family to count as rich
    [int]$RichFloor   = 70,         # keep layouts from this many chunks up
    # Only spots whose triage already reached this. Measured (cycle #414, 6 exhausts): the
    # exhaust matched triage's best 4 times and beat it by +0.52 / +0.24 twice, for +35% cycle
    # time - triage usually finds its family's best already. So it is kept as near-record
    # insurance only, where +0.5 can turn a 67.8 into a record.
    [double]$RichMinCQ = 66.0,
    # 15s, was 40s. Same reasoning as record_cycle.ps1's -Seconds: this is a
    # wall-clock budget and the hunt now runs at 41.9M seeds/s (measured), so
    # 15s draws ~630M seeds where the original 40s drew ~160M - still ~4x the
    # depth this was calibrated at. Pushes are rare per cycle (anchor + up to
    # -PushTop), so the ~75s freed goes straight into hunting more new spots,
    # which is what the tail fit says actually moves the record.
    [int]$PushSeconds = 15,
    # Only push a triage spot that already showed it can reach high counts.
    # Measured across every cycle so far: 34 non-anchor pushes produced ZERO
    # seeds and 7 produced something - and all 7 were the anchor. Triage bests
    # at those spots run 61-63 cq, i.e. ~66-67 chunks, so asking them for 69+
    # in 40s is asking for a count they have never once produced. That is ~120s
    # per cycle bought nothing. A spot that scored >= this in triage has
    # demonstrated the count; anything below is skipped and the time goes to
    # hunting new spots instead. The anchor bypasses this gate entirely.
    [double]$PushMinCQ = 64.0,
    # ANCHOR: a known-productive spot+family the push ALWAYS includes, ahead of
    # whatever the triage ranked. Measured, and the reason this exists: three
    # floor-70 pushes on triage-ranked spots produced ZERO seeds in 40s each,
    # because 70-chunk layouts are vanishingly rare at ordinary spots - and the
    # floor cannot manufacture them, it only filters what the hunt already
    # found. The record family is the one place 70c draws happen reliably (it
    # has produced three distinct 70c layouts: 94.3%, 92.9%, 91.8%), so the
    # push budget is worth more spent there. Target: a 70c layout packing
    # >= 94.4%. Geometry permits up to 100% at 70c (the 70 heaviest cells are
    # all full-weight), so 94.3% is a sampling record, not a ceiling.
    [string]$AnchorSpot   = "3680,6992",
    [string]$AnchorMask   = "0xFDE0F",
    [string]$AnchorVal    = "0x70802",
    [switch]$NoAnchor,
    [switch]$NoSweep,                # skip the all-families sweep before each push
    [int]$SweepFloor  = 55,          # chunk floor the sweep counts hits at
    # Hard cap on straight-line distance from spawn, in blocks. A scan built
    # with --range-x 10000 --range 10000 bounds a 10k BOX, whose corners reach
    # 14142 blocks - so "10k scan" alone does not mean "within 10k". 0 = no cap.
    # -ForceMask: override the DERIVED mask before the family sweep. Measured
    # 2026-09-10: across 13 spots the derivation is the sweep-best family 7
    # times, but it MISSED AT BOTH RECORD SPOTS - at 40752,5424 by one bit
    # (rank 40), and at 3696,6992 by choosing a DIFFERENT MASK, which no
    # val-sweep can recover from. A bad val is recoverable; a bad mask is not.
    # 0xFDE0F won 4 of 5 spots tested and beat 40752,5424's own native mask
    # (274 vs 235 hits). Empty string = keep the derived mask.
    [string]$ForceMask  = "",
    # seeds per family for the LIGHT triage sweep under -ForceMask (the push
    # sweep uses 400000). 1/8 the cost; it only has to rank vals, not measure them.
    [int]$TriageSweepSeeds = 50000,
    # WINDOWED triage sweep (hotspot_scan --sweep-rx/--sweep-rz): a family is ranked by its
    # best AFK chunk within +-TriageRx X / +-TriageRz Z of the spot, not the centre alone -
    # the hunt that follows searches that whole neighbourhood. Paired test, 30 hot spots, one
    # 14-bit mask (experiments\triage_window_test.ps1): picks differed at 22; windowed family
    # better at 9, centre at 6; spots whose pick had any 64+ layout 18 vs 14. Weak but
    # one-sided; costs ~1.5 s/spot. 0/0 = the old centre-only sweep.
    [int]$TriageRx = 3, [int]$TriageRz = 2,
    [int]$MaxDist     = 10000,
    # Falls back to the old one-process-per-spot behaviour (Start-Process +
    # poll + kill). Use this if the persistent worker misbehaves; every spot
    # still runs, just ~199ms/spawn slower (measured) - the same cost this
    # was built to remove. See Start-SlimeWorker/Invoke-Hunt below.
    [switch]$NoWorker
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
# Start-Process -WindowStyle exists only on Windows; PowerShell 7 on Linux rejects it and the process never
# starts (seen: a spot's seeds went unscored). Splat it in on Windows only.
$hideWin = if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { @{ WindowStyle = 'Hidden' } } else { @{} }
Set-Location $root
$script:runStart = Get-Date   # scratch this run creates in main\work is removed at the end
New-Item -ItemType Directory -Force -Path main\work | Out-Null

if (-not $Commands) {
    $newest = Get-ChildItem (Join-Path $root "main\commands\commands_*.csv") -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { Write-Host "no main\commands\commands_*.csv - run hotspot_scan --scan first" -ForegroundColor Red; exit 1 }
    $Commands = $newest.FullName
}
if (-not (Test-Path $Commands)) { Write-Host "no such file: $Commands" -ForegroundColor Red; exit 1 }
foreach ($e in @("slime_gpu.exe","slime_refine.exe")) {
    if (-not (Test-Path (Join-Path $root $e))) { Write-Host "missing $e - run build.ps1" -ForegroundColor Red; exit 1 } }
Write-Host "pipeline: $Commands   ${Seconds}s/spot, top $Top, floor $Floor" -ForegroundColor Cyan

function SeedList($path) {
    if (-not (Test-Path $path)) { return @() }
    $t = Get-Content $path -Raw -ErrorAction SilentlyContinue
    if (-not $t) { return @() }
    # Accept only well-formed seeds. slime_gpu appends "<seed>," incrementally,
    # so a hunt killed mid-write leaves a PARTIAL token - observed in the wild
    # as a file containing just "-". Splitting on commas counts that fragment as
    # a seed; slime_refine then parses it as 0 and files a bogus "...0.txt"
    # result. Hunts are killed on a timer every single spot, so this is routine,
    # not an edge case. Also strips a stray BOM if one ever gets in.
    return @(($t -split ',') |
             ForEach-Object { $_.Trim([char]0xFEFF, [char]' ', [char]"`t", [char]"`r", [char]"`n") } |
             Where-Object { $_ -match '^-?\d+$' })
}
function SeedCount($path) { return (SeedList $path).Count }

# ---- PERSISTENT WORKER --------------------------------------------------
# A fresh slime_gpu.exe process pays ~199ms for CUDA context creation +
# constant uploads + teardown (measured). This pipeline runs up to -Top
# (default 120) triage spots plus several pushes PER CYCLE, one process each
# under the old model - up to ~16% of a cycle spent on plumbing, not
# hunting, worse on dead families where give-up itself costs ~0.37s. Instead:
# start ONE slime_gpu.exe --worker for this whole pipeline run, and send it
# each spot's hunt as a stdin line (--worker keeps one CUDA context alive
# across all of them). The per-spot wall-clock budget that used to be
# enforced by killing the process is now --time-limit-ms, handled INSIDE the
# hunt loop - killing a shared persistent process is not an option, it would
# tear down every spot queued after it.
function Start-SlimeWorker($root) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $root "slime_gpu.exe"
    $psi.Arguments = "--worker"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $root
    # Note: ProcessStartInfo.StandardInputEncoding (which would ask for a
    # BOM-less writer here) does not exist on this .NET Framework / Windows
    # PowerShell 5.1 - tried it, threw PropertyAssignmentException at
    # runtime. .NET's default StreamWriter emits a UTF-8 preamble on its
    # first write instead, which broke the worker's FIRST spot line (a real
    # bug caught by testing, not theorized). Fixed on the C++ side instead:
    # slime_gpu's --worker strips a leading BOM defensively on every line it
    # reads, so this is harmless here - verified byte-identical worker output
    # including as the very first line of a fresh worker.
    $proc = [System.Diagnostics.Process]::Start($psi)
    # Drain stderr ASYNCHRONOUSLY - a synchronous Peek()/EndOfStream check on
    # an anonymous pipe blocks until data OR stream-close, which would hang
    # this script the moment a spot line ever produced zero stderr output.
    $sub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
        if ($EventArgs.Data) { Write-Host "[worker] $($EventArgs.Data)" -ForegroundColor DarkYellow }
    }
    $proc.BeginErrorReadLine()
    $ready = $proc.StandardOutput.ReadLine()
    if ($ready -ne "WORKER READY") {
        Write-Host "  worker did not start cleanly (got: '$ready') - falling back to per-process spawning" -ForegroundColor Red
        Unregister-Event -SourceIdentifier $sub.Name -ErrorAction SilentlyContinue
        try { $proc.Kill() } catch {}
        return $null
    }
    return [pscustomobject]@{ Process = $proc; Sub = $sub }
}

# Send/wait split into primitives so the triage loop below can overlap: send
# spot N+1's line without blocking, do CPU-only work (scoring), THEN wait for
# its sentinel. Invoke-SlimeWorker (send+wait together) is the synchronous
# convenience wrapper used wherever there's nothing to overlap it with (the
# push loop, and the single-request path inside Invoke-ClimbScan).
function Send-SlimeWorker($w, $argLine) {
    try {
        $w.Process.StandardInput.WriteLine($argLine)
        $w.Process.StandardInput.Flush()
        return $true
    } catch { return $false }
}

# Waits for the ===SPOT-DONE=== sentinel, discarding output lines. Returns
# $false if the worker's stdout stream ended instead (process died).
function Wait-SlimeWorker($w) {
    while ($true) {
        $l = $w.Process.StandardOutput.ReadLine()
        if ($null -eq $l) { return $false }
        if ($l -eq "===SPOT-DONE===") { return $true }
    }
}

# Same as Wait-SlimeWorker but CAPTURES the lines instead of discarding them -
# --climb-scan prints its result table to stdout rather than a seeds-out
# file, so the caller needs the text back (see Invoke-ClimbScan).
function Read-SlimeWorkerLines($w) {
    $lines = @()
    while ($true) {
        $l = $w.Process.StandardOutput.ReadLine()
        if ($null -eq $l) { return [pscustomobject]@{ Ok = $false; Lines = $lines } }
        if ($l -eq "===SPOT-DONE===") { return [pscustomobject]@{ Ok = $true; Lines = $lines } }
        $lines += $l
    }
}

function Invoke-SlimeWorker($w, $argLine) {
    if (-not (Send-SlimeWorker $w $argLine)) { return $false }
    return Wait-SlimeWorker $w
}

# --climb-scan sweep of a seed's high bits, worker-first with the same
# per-process fallback pattern as Invoke-Hunt. Every productive triage spot
# used to pay this as a SECOND separate ~199ms spawn, even after the hunt
# itself moved onto the worker - slime_gpu.cu's runWorkerLoop now accepts a
# --climb-scan line exactly like a plain hunt line (see runClimbScan there).
# --climb-top 20, was 5: the top few GPU variants are usually exact ties (same
# chunk-aligned layout - measured: all 5 tied at 16642 blocks), so 5 gave refine
# one real candidate. 20 costs ~0.3 s more of refine and gives it several.
function Invoke-ClimbScan($seedVal, $cx, $cz, $lo = 24, $bits = 24, $top = 20) {
    $argLine = "--climb-scan --seed $seedVal --center-x $cx --center-z $cz --m-chunks 6 --climb-lo $lo --climb-bits $bits --climb-top $top"
    if ($script:worker) {
        if (Send-SlimeWorker $script:worker $argLine) {
            $r = Read-SlimeWorkerLines $script:worker
            if ($r.Ok) { return $r.Lines }
        }
        Write-Host "  worker died - falling back to per-process spawning for the rest of this run" -ForegroundColor Red
        Stop-SlimeWorker $script:worker
        $script:worker = $null
    }
    return & (Join-Path $root "slime_gpu.exe") --climb-scan --seed $seedVal --center-x $cx --center-z $cz `
        --m-chunks 6 --climb-lo $lo --climb-bits $bits --climb-top $top 2>&1
}

# Climb one scored seed ($row: a slime_refine csv row) and return the best refined
# row - the seed itself when no variant beats it. Used for the standard 24-bit
# climb, the deep 28-bit climb, and on push results (which were never climbed).
function Climb-Seed($row, $cx, $cz, $lo, $bits, $label) {
    $cs = Invoke-ClimbScan $row.seed $cx $cz $lo $bits 20
    # A deep climb (bits $lo..47) covers EVERY seed sharing this seed's low $lo bits,
    # so re-climbing any of them - including its own result - repeats the same search.
    # Log the coverage so reclimb_top.ps1 can skip it.
    if ($lo -le 20) {
        $dc = Join-Path $root "main\records\deep_climbed.csv"
        if (-not (Test-Path $dc)) { Set-Content $dc "SpotX,SpotZ,Lo,LowBits,Seed" -Encoding ascii }
        Add-Content $dc -Encoding ascii ("{0},{1},{2},{3},{4}" -f $cx, $cz, $lo, ([int64]$row.seed -band ((1L -shl $lo) - 1)), $row.seed)
    }
    $vseeds = @(foreach ($ln in $cs) {
        # variant rows: "<blocks> <cq> (<x>,<z>) <seed>"
        if ($ln -match '^\s*\d+\s+[0-9.]+\s+\(\s*-?\d+,\s*-?\d+\)\s+(-?\d+)\s*$' -and $Matches[1] -ne $row.seed) { $Matches[1] }
    }) | Select-Object -Unique
    if (-not $vseeds) { return $row }
    $cf = Join-Path $root ("main\work\climb_{0}_{1}.csv" -f $cx,$cz)
    [System.IO.File]::WriteAllText($cf, ($vseeds -join ","))
    $csum = Join-Path $root ("main\work\climbcq_{0}_{1}.csv" -f $cx,$cz)
    $ca = @("--seeds",$cf,"--center-x",$cx,"--center-z",$cz,"--radius",$Radius,
            "--csv",$csum,"--quiet","--family",("pipe_{0}_{1}" -f $cx,$cz),"--no-images","--no-logs")
    & (Join-Path $root "slime_refine.exe") @ca *> $null
    if (Test-Path $csum) {
        $vb = Import-Csv $csum | Sort-Object { [double]$_.cq } -Descending | Select-Object -First 1
        if ($vb -and [double]$vb.cq -gt [double]$row.cq) {
            Write-Host ("      {0}: {1} -> {2} cq (variant)" -f $label,$row.cq,$vb.cq) -ForegroundColor Yellow
            return $vb
        }
    }
    return $row
}

function Stop-SlimeWorker($w) {
    if (-not $w) { return }
    try {
        $w.Process.StandardInput.WriteLine("--quit")
        $w.Process.StandardInput.Flush()
        if (-not $w.Process.WaitForExit(3000)) { $w.Process.Kill() }
    } catch { try { $w.Process.Kill() } catch {} }
    Unregister-Event -SourceIdentifier $w.Sub.Name -ErrorAction SilentlyContinue
}

# One spot's hunt, worker-first with a per-process fallback - shared by the
# triage loop and the push loop below, which previously each had their own
# copy of the Start-Process/poll/kill logic. $before is the seeds-out file's
# count before this call, needed by the fallback path's dead-spot check.
function Invoke-Hunt($a, $out, $secs, $before) {
    if ($script:worker) {
        $ok = Invoke-SlimeWorker $script:worker ("$a --time-limit-ms $($secs * 1000)")
        if ($ok) { return }
        Write-Host "  worker died - falling back to per-process spawning for the rest of this run" -ForegroundColor Red
        Stop-SlimeWorker $script:worker
        $script:worker = $null
    }
    # Fallback: one process per spot (pre-worker behaviour, unchanged). Dead
    # spots normally self-abort via --give-up-after well before this ever
    # matters (~0.37s on this box), so the 5s poll below is now mostly a
    # safety net for hunts --give-up-after can't judge (e.g. the anchor,
    # which disables it) rather than the main defense it used to be.
    $p = Start-Process -FilePath ".\slime_gpu.exe" -ArgumentList $a `
         -WorkingDirectory $root -PassThru @hideWin
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $secs) {
        Start-Sleep -Milliseconds 500
        if ($sw.Elapsed.TotalSeconds -ge 5 -and ((SeedCount $out) - $before) -eq 0) { break }
    }
    if (-not $p.HasExited) { try { $p.Kill() } catch {}; $p.WaitForExit() }
}

# The family sweep defaults to a FIXED rng seed, so with -ForceMask the same
# spot would re-derive the same best val every run. Rotate it per run so a
# fixed mask still samples the 16384 families differently each time.
# Derived from the COMMANDS FILE name (which carries the cycle's rng-seed),
# not the clock: the same rng-seed now gives the same sweep, so a cycle is
# reproducible and two arms of a controlled test sample vals identically.
# Still rotates per cycle, because the rng-seed does.
$script:sweepRng = 0; foreach ($ch in ([IO.Path]::GetFileName($Commands)).ToCharArray()) { $script:sweepRng = (($script:sweepRng * 31) + [int]$ch) -band 0x7FFFFFFF }
$worker = if ($NoWorker) { $null } else { Start-SlimeWorker $root }
if ($worker) { Write-Host "persistent GPU worker started (one CUDA context for this whole run)" -ForegroundColor DarkGray }
else { Write-Host "worker disabled - one process per spot (slower, ~199ms/spawn)" -ForegroundColor DarkGray }

# Score only the seeds a hunt ACTUALLY ADDED, not the whole accumulated file.
# slime_gpu appends, so the new ones are the tail. Seed files grow every
# session (1992 banked across 72 files already, largest 268), and rescoring a
# 268-seed file to evaluate 5 new seeds costs ~3.5s of pure waste - a cost that
# rises every cycle forever. Writing the tail to a temp file keeps per-cycle
# scoring flat instead of linear in everything ever found.
# Images cost ~2x scoring time (1.4s vs 0.6s on an 86-seed file) and almost all
# of them are 55-63 cq layouts nobody will ever open. So score with --no-images
# and regenerate the PNG for a single seed only when it clears -ImageMinCQ.
# One seed with images is ~0.1s, so this pays for itself the moment more than a
# couple of seeds are scored.
function SaveImage($seed, $cx, $cz, $family, $radius, $root) {
    if (-not $seed) { return }
    $f = Join-Path $root ("main\work\img_{0}_{1}.csv" -f $cx,$cz)
    [System.IO.File]::WriteAllText($f, [string]$seed)
    & (Join-Path $root "slime_refine.exe") --seeds $f --center-x $cx --center-z $cz `
        --radius $radius --quiet --family $family *> $null
    Remove-Item $f -ErrorAction SilentlyContinue   # one-seed temp file (one per spot used to pile up in main\work)
}

# File a finished result into main\records\<tier>\ so the good ones are not
# buried among thousands of ordinary scores. Was ONE flat folder; heat mode
# yields ~10 results of 64+ per cycle, so a flat folder would bury the top ones
# under hundreds of 64s within a week. Now:
#   main\records\index.csv      one row per result - the thing to sort/filter
#   main\records\<tier>\        <cq>_<seed>.txt/.png, tier = floor(cq): 64\ 65\ 66\ 67\
#   main\records\RECORD.*       only results VERIFIED IN GAME (filed by hand)
# Only the peak position per seed is kept, and a seed already indexed at the
# same position is not indexed twice. The artefacts are MOVED out of
# main\scores\ (scoring there runs --no-logs; SaveImage writes them just for
# this seed), so nothing is left behind twice.
# IN-PROCESS INDEX (2026-10-03). The duplicate tests below used to hit index.csv per filed farm: two
# Select-String passes plus a full Import-Csv, ~1.8 s per searched spot at 4.42 farms/spot and growing with
# the file (measured 3.31 s/farm at 65k rows = 3.5x the GPU cost - an O(spots^2) term). Now index.csv is
# parsed ONCE per process with the same Import-Csv as before, so the parse semantics are unchanged, and the
# maps are kept current as rows are appended. Assumes one filer per process, which is how the filing worker
# runspace is built; if filing is ever split across runspaces, each would need to share these maps.
$script:IdxPos = $null   # "seed|x|z" -> $true          (was: Select-String -SimpleMatch ",$seed,$x,$z,")
$script:IdxCq = $null    # cq string -> list of {X,Z}   (was: Import-Csv | Where CQ -eq ... )
$script:IdxLen = -1      # index.csv length when the maps were last in sync with the file
function Ensure-Index($idx) {
    # Rebuild if ANOTHER writer appended since we last looked. phase_spots.ps1 has two session states that both
    # call ArchiveResult (the filing worker runspace and Test-Cut on the main runspace), each with its own copy of
    # these maps, so "one filer per process" is not true; a second filing process would be invisible too. The
    # length check costs one stat per farm instead of a full re-read, and keeps the duplicate test honest.
    if ($null -ne $script:IdxPos) {
        $len = if (Test-Path $idx) { (Get-Item -LiteralPath $idx).Length } else { 0 }
        if ($len -eq $script:IdxLen) { return }
    }
    $script:IdxPos = @{}; $script:IdxCq = @{}
    if (Test-Path $idx) {
        foreach ($r in (Import-Csv $idx)) {
            $script:IdxPos["$($r.Seed)|$($r.X)|$($r.Z)"] = $true
            if ($r.X) {
                if (-not $script:IdxCq.ContainsKey($r.CQ)) {
                    $script:IdxCq[$r.CQ] = New-Object System.Collections.Generic.List[object] }
                $script:IdxCq[$r.CQ].Add([pscustomobject]@{ X = [long]$r.X; Z = [long]$r.Z }) } } }
    $script:IdxLen = if (Test-Path $idx) { (Get-Item -LiteralPath $idx).Length } else { 0 }
}
function Add-IndexEntry($cqStr, $seed, $x, $z, $idx) {
    if ($null -eq $script:IdxPos) { return }
    $script:IdxPos["$seed|$x|$z"] = $true
    if ($x) {
        if (-not $script:IdxCq.ContainsKey($cqStr)) {
            $script:IdxCq[$cqStr] = New-Object System.Collections.Generic.List[object] }
        $script:IdxCq[$cqStr].Add([pscustomobject]@{ X = [long]$x; Z = [long]$z }) }
    # our own append must not look like someone else's
    if ($idx -and (Test-Path $idx)) { $script:IdxLen = (Get-Item -LiteralPath $idx).Length }
}
function ArchiveResult($cq, $seed, $cx, $cz, $family, $radius, $root, $fkey = "") {
    $tier = [math]::Floor([double]$cq)
    if ($tier -lt 66) { return }   # 66+ only (2026-09-12: the 64/65 tiers were retired; 66+ is the kept data)
    $recDir = Join-Path $root "main\records"
    $dir = Join-Path $recDir ([string]$tier)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    SaveImage $seed $cx $cz $family $radius $root
    $src = Join-Path $root ("main\scores\{0}" -f $family)
    $cqStr = "{0:0.00}" -f [double]$cq
    # exact name match: "-123" must not be taken for seed "123"
    $arts = @(if (Test-Path $src) { Get-ChildItem $src -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -eq [string]$seed } })
    # index row, parsed from the result's own log so it matches the files exactly - read BEFORE filing,
    # so a duplicate is never filed (was: files moved first, duplicate check after - 12 farms' files sat
    # in the tier folders with no index row)
    $x = ""; $z = ""; $chunks = ""; $blocks = ""
    $srcTxt = $arts | Where-Object { $_.Extension -eq '.txt' } | Select-Object -First 1
    if ($srcTxt) {
        $l = Select-String -Path $srcTxt.FullName -Pattern 'BEST BY BLOCKS:\s+(\d+) blocks \(([\d.]+) cq\) / (\d+) chunks at \((-?\d+),(-?\d+)\)' | Select-Object -First 1
        if ($l) { $m = $l.Matches[0].Groups; $blocks = $m[1].Value; $chunks = $m[3].Value; $x = $m[4].Value; $z = $m[5].Value }
    }
    $idx = Join-Path $recDir "index.csv"
    Ensure-Index $idx
    $dup = $script:IdxPos.ContainsKey("$seed|$x|$z")
    # Same farm under another seed: seeds that agree in their low 48 bits make the same world, a family
    # exhaust (--enumerate) finds the 48-bit form of a farm the hunt found with random high bits, and the
    # phase search refines up to 3 seeds per layout - same cq at the same AFK point, or a few blocks off
    # when the best point shifts with chunks outside the searched window. One row, one set of files per farm.
    # (2026-10-03) the cq bucket replaces the text pre-filter and the full parse: same rows, same test
    if (-not $dup -and $x -and $script:IdxCq.ContainsKey($cqStr)) {
        $lx = [long]$x; $lz = [long]$z
        foreach ($p in $script:IdxCq[$cqStr]) {
            if ([math]::Abs($p.X - $lx) -le 8 -and [math]::Abs($p.Z - $lz) -le 8) { $dup = $true; break } } }
    # slime_refine's scratch folder (main\scores\<family>) is empty once this farm's files are filed or dropped -
    # remove it here: the exact search borrows only these functions, never the end-of-run tidy below, so
    # one empty folder per spot piled up (111 by 2026-09-13)
    $dropSrc = { if ((Test-Path $src) -and -not (Get-ChildItem $src -Force -ErrorAction SilentlyContinue)) { Remove-Item $src -Force -ErrorAction SilentlyContinue } }
    if ($dup) { $arts | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }; & $dropSrc; return }   # this call's own fresh output
    $txt = $null
    foreach ($a in $arts) {
        $dst = Join-Path $dir ("{0}_{1}{2}" -f $cqStr, $seed, $a.Extension)
        Move-Item $a.FullName -Destination $dst -Force -ErrorAction SilentlyContinue
        if ($a.Extension -eq '.txt') { $txt = $dst }
    }
    & $dropSrc
    if (-not (Test-Path $idx)) {
        Set-Content -Path $idx -Value "Date,CQ,Eff,Chunks,Blocks,Seed,X,Z,Family,SpotX,SpotZ,Run,File" -Encoding ascii
    }
    $eff = if ($chunks) { "{0:0.0}" -f ([double]$cq / [double]$chunks * 100) } else { "" }
    $run = [IO.Path]::GetFileNameWithoutExtension($Commands) -replace '^commands_',''
    $rel = if ($txt) { $txt.Substring($root.Length).TrimStart('\', '/') } else { "" }   # '/' too: Linux paths
    Add-Content -Path $idx -Encoding ascii -Value ("{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12}" -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm'), $cqStr, $eff, $chunks, $blocks, $seed, $x, $z, ($fkey -replace ',', ';'), $cx, $cz, $run, $rel)   # keys like PHASE@X,Z carry a comma; the row is not quoted
    Add-IndexEntry $cqStr $seed $x $z $idx
    Log-Over66 $cqStr $seed $x $z $cx $cz $chunks $eff $fkey $run $root
}

# main\records\over70_y-39\<estimate>-<cq>-<seed>.png for a newly filed 66+ farm: afk_rescan.exe's estimate of what
# /perimeterinfo reads with the player's feet at y -39 over the -64 floor (no inner circle, outer 125.7, best AFK
# point within +-48 blocks). A side hint, not a ranking; ~0.1 s per new 66+ farm. afk_rescan.ps1 backfills and
# renames measured farms to their in-game number. Prints "BIG (estimate ...)" above the best in-game count.
function Add-Y39Image($png, $seed, $x, $z, $cq, $root) {
    $exe = Join-Path $root "afk_rescan.exe"
    if (-not (Test-Path $exe) -or -not (Test-Path -LiteralPath $png) -or -not $x) { return }
    $dir = Join-Path $root "main\records\over70_y-39"; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $in = Join-Path $root ("main\work\y39_{0}.csv" -f $seed); $out = "$in.out"
    [IO.File]::WriteAllText($in, "seed,x,z`n$seed,$x,$z`n")
    & $exe --in $in --out $out --dy 24 --window 48 | Out-Null
    $r = $null; if (Test-Path $out) { $r = Import-Csv $out | Select-Object -First 1 }
    Remove-Item $in, $out -ErrorAction SilentlyContinue
    if (-not $r) { return }
    $est = [int]$r.blocks_dy_best; $p = Join-Path $dir ("{0}-{1}-{2}.png" -f $est, $cq, $seed)   # peri-score-seed (the project owner's format)
    Copy-Item -LiteralPath $png $p -Force      # one image per farm: slime_refine draws no inner ring any more
    $stamp = ([datetime]'2026-01-01').AddSeconds(5 * $est); (Get-Item -LiteralPath $p).LastWriteTime = $stamp; (Get-Item -LiteralPath $p).CreationTime = $stamp
    $mf = Join-Path $root "main\records\measured_in_game.csv"
    if (Test-Path $mf) {
        $meas = @(Import-Csv $mf); $top = [int]($meas | ForEach-Object { [int]$_.ingame } | Measure-Object -Maximum).Maximum
        $twin = @($meas | Where-Object { [math]::Abs([long]$_.x - [long]$x) -le 64 -and [math]::Abs([long]$_.z - [long]$z) -le 64 }).Count
        if ($top -and $est -gt $top -and -not $twin) { "BIG (estimate - worth an in-game check): {0} seed {1} - tool estimates {2} at -39 (AFK {3},{4}); best measured so far {5}" -f $cq, $seed, $est, $r.best_x, $r.best_z, $top }
    }
}

# Every 66+ farm, in one short file (main\records\over66.csv) with its spot's heat and
# hot line, plus a ready-to-paste in-game setup (perimeter_setup) beside its record.
function Log-Over66($cq, $seed, $x, $z, $cx, $cz, $chunks, $eff, $fkey, $run, $root) {
    if ([double]$cq -lt 66 -or -not $x) { return }
    $f = Join-Path $root "main\records\over66.csv"
    if (-not (Test-Path $f)) { Set-Content $f "Date,CQ,Chunks,Eff,Seed,X,Z,Heat40,Line,Family,SpotX,SpotZ,Run,Perimeter" -Encoding ascii }
    if (Select-String -Path $f -SimpleMatch -Pattern ",$seed," -Quiet) { return }
    $scx = [int][math]::Floor([double]$cx / 16); $scz = [int][math]::Floor([double]$cz / 16)
    # the spot's heat40: the MEASURED spot list first (spot_top.csv, the list the exact search runs on), then
    # the old model-era heat_cache.csv (loaded only on a miss). Was: heat_cache only, re-read (3.3 MB, ~1 s)
    # for every farm - and the measured spots are not in it, so Heat40 came out blank for them.
    if ($null -eq $script:spotHeat) { $script:spotHeat = @{}
        $st = Join-Path $root "main\theory\heat\spot_top.csv"
        if (Test-Path $st) { foreach ($r in (Import-Csv $st)) { $script:spotHeat["$([int]$r.cx),$([int]$r.cz)"] = [double]$r.heat40 } } }
    $k = "$scx,$scz"
    if (-not $script:spotHeat.ContainsKey($k) -and -not $script:spotHeatOld) { $script:spotHeatOld = $true
        $hc = Join-Path $root "main\theory\heat\heat_cache.csv"
        if (Test-Path $hc) { foreach ($r in (Import-Csv $hc)) { $k2 = "$([int]$r.cx),$([int]$r.cz)"
            if (-not $script:spotHeat.ContainsKey($k2)) { $script:spotHeat[$k2] = [double]$r.p40 / 2.1e-5 } } } }
    $heat = $(if ($script:spotHeat.ContainsKey($k)) { "{0:0.0}" -f $script:spotHeat[$k] } else { "" })
    $line = [math]::Round(($scz - 48.5) / 96.875)
    $dir = Join-Path $root ("main\records\{0}" -f [math]::Floor([double]$cq))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # perimeter setups are made ON REQUEST only (2026-09-12), not for every farm:
    #   perimeter_setup.exe --seed <seed> --center-x <x> --center-z <z>  > main\records\perimeter\<cq>_<seed>_perimeter.txt
    # and its image into the one-folder gallery of every 66+ farm
    $png = Join-Path $dir ("{0:0.00}_{1}.png" -f [double]$cq, $seed)
    # galleries (the normal over70_images and over70_y-39) only for 70+ cq (project owner, 2026-09-22); 66-69 farms are still filed
    if ((Test-Path $png) -and [double]$cq -ge 70) {
        $gal = Join-Path $root "main\records\over70_images"
        New-Item -ItemType Directory -Force -Path $gal | Out-Null
        Copy-Item $png $gal -Force
        # gallery file date = a stamp from its cq (all on 2026-01-05/06), so Explorer shows ONE date group
        # and "sort by date, newest first" = best cq first; the real find date is in over66.csv
        $stamp = ([datetime]'2026-01-01').AddMinutes([double]$cq * 100)
        $gp = Join-Path $gal (Split-Path $png -Leaf); (Get-Item $gp).LastWriteTime = $stamp; (Get-Item $gp).CreationTime = $stamp
        # side folder over70_y-39: the same image named by the raised-AFK estimate - a hint only; a failure here never stops filing
        try { Add-Y39Image $png $seed $x $z $cq $root } catch { }
    }
    Add-Content $f -Encoding ascii ("{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13}" -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm'), $cq, $chunks, $eff, $seed, $x, $z, $heat, $line, ($fkey -replace ',', ';'), $cx, $cz, $run, "")   # no raw comma in the key (unquoted row)
}

function NewSeedsFile($path, $before, $tmp) {
    # @(...) IS LOAD-BEARING. PowerShell unwraps a single-element array on
    # function return, so when a hunt produced exactly ONE seed, $all came back
    # as a STRING and $all[0..0] sliced its first CHARACTER instead of taking
    # the first element - writing a seed file containing "8" instead of
    # "8533657114822319702". slime_refine then scored seed 8, filed a ~23-38 cq
    # junk result (the random rate), and hunt_pipeline recorded THAT as the
    # family's BestCQ in the ledger, so the bogus value stuck and the family
    # could be retired on it.
    #
    # It only bites on exactly-one-seed hunts, which is why it stayed hidden:
    # at the old 12s triage most productive spots returned several seeds. At the
    # retuned 4s budget single-seed spots are common, and this produced 8 junk
    # results in a single cycle. SeedCount is unaffected (.Count is 1 for a
    # scalar too, which is the right answer) - only the slice was wrong.
    $all = @(SeedList $path)
    if ($all.Count -le $before) { return $null }
    $new = @($all[$before..($all.Count - 1)])
    [System.IO.File]::WriteAllText($tmp, ($new -join ","))
    return $tmp
}

# ---- FAMILY LEDGER ----------------------------------------------------------
# A family is the (mask,val) residue class, and the same one recurs across
# scans: the derivation is deterministic per rng-seed but converges on the same
# strong families often (observed: identical (mask,val) -> identical best seed
# re-found on separate cycles). Hunting a family again that already got its
# hunts AND a wide core sweep, without its best moving, is a pure replay.
# Rule: a (mask,val) seen >= 2 times with no best-cq improvement is MINED -
# skip its hunt, keep its known best in the table, spend the 12s elsewhere.
$ledgerPath = Join-Path $root "main\families.csv"
$ledger = @{}
if (Test-Path $ledgerPath) {
    foreach ($e in (Import-Csv $ledgerPath)) { $ledger[$e.Key] = $e }
}
# NEVER RUN A FAMILY TWICE: every (mask,val) in a PRIOR run's ledger is off-limits.
# $usedThisRun stops two spots in this run picking the same family - the key has
# no spot in it, so family X at spot A and family X at spot B is one family.
$priorKeys = @{}; foreach ($k in $ledger.Keys) { $priorKeys[$k] = 1 }
$usedThisRun = @{}

# ---- PHASE 1: filter candidates (mined-family / distance skips), exactly as
# before, but WITHOUT hunting yet - this separates "which spots are eligible"
# from "hunting them" so Phase 2 below can look ahead to the next eligible
# spot for prefetching. Stops at $Top eligible spots, same as the old single
# loop's "if ($i -ge $Top) break".
$rows = @()
$eligible = @()
foreach ($line in (Get-Content $Commands | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith('#') })) {
    if ($eligible.Count -ge $Top) { break }
    if ($line -notmatch '--center-x\s+(-?\d+)') { continue }; $cx = [int]$Matches[1]
    if ($line -notmatch '--center-z\s+(-?\d+)') { continue }; $cz = [int]$Matches[1]
    if ($line -notmatch '--seeds-out\s+(\S+)')  { continue }; $out = $Matches[1]
    $mask = if ($line -match '--fix-mask\s+(\S+)') { $Matches[1] } else { "-" }
    $val  = if ($line -match '--fix-val\s+(\S+)')  { $Matches[1] } else { "-" }
    # Skip before spending hunt time, not after - a spot outside the radius is
    # not a candidate however well it scores.
    $spotDist = [int][math]::Sqrt([double]($cx*$cx) + [double]($cz*$cz))
    if ($MaxDist -gt 0 -and $spotDist -gt $MaxDist) {
        Write-Host ("  skip ({0,6},{1,6})  {2} blocks out, past -MaxDist {3}" -f $cx,$cz,$spotDist,$MaxDist) -ForegroundColor DarkGray
        continue
    }
    # ---- -ForceMask at TRIAGE, not only at push. Before this, triage hunted the
    # DERIVED family and the push gate (-PushMinCQ) read that triage cq, so the
    # derivation - which missed at BOTH record spots, once by choosing a mask the
    # record family did not exist under - still decided which spots the forced
    # mask ever got to try. Now a light sweep under the forced mask picks the val,
    # and the forced family is what gets triaged and gated.
    if ($ForceMask) {
        $tsf = Join-Path $root ("main\work\tsweep_{0}_{1}.csv" -f $cx,$cz)
        & (Join-Path $root "hotspot_scan.exe") --family-sweep --center-x $cx --center-z $cz `
            --sweep-mask $ForceMask --sweep-n 16384 --sweep-seeds $TriageSweepSeeds `
            --sweep-floor $SweepFloor --sweep-rx $TriageRx --sweep-rz $TriageRz --rng-seed $script:sweepRng --sweep-out $tsf *> $null
        $picked = $null
        if (Test-Path $tsf) {
            # the sweep writes hits-descending; take the best val whose family has
            # NEVER been run - not in any prior run and not picked by another spot
            foreach ($sv in (Import-Csv $tsf)) {
                if ([int]$sv.hits -le 0) { break }
                $k = "$ForceMask|$($sv.val)"
                if (-not $priorKeys.ContainsKey($k) -and -not $usedThisRun.ContainsKey($k)) { $picked = $sv.val; break }
            }
        }
        if (-not $picked) {
            Write-Host ("  skip ({0,6},{1,6})  no never-run family with hits under {2}" -f $cx,$cz,$ForceMask) -ForegroundColor DarkGray
            continue
        }
        $mask = $ForceMask; $val = $picked
        $line = ($line -replace '--fix-mask\s+\S+', "--fix-mask $ForceMask") -replace '--fix-val\s+\S+', "--fix-val $picked"
    }
    # NEVER RUN A FAMILY TWICE. Replaces the old rule ("mined" only at Times >= 2,
    # and an improving family reset to Times=1 so it kept being re-hunted). Any
    # (mask,val) from a prior run is now skipped outright. Within one run a family
    # still gets its triage AND its push - one treatment, not a repeat.
    $fkey = "$mask|$val"
    # A FULL 20-bit family (record_cycle -Families) is a spot-specific search: the same
    # 2^28 seeds at another spot are a different farm, and family_spots.ps1 picks each
    # spot's own best families. So its key carries the spot. Older keys are unchanged.
    if ($mask -eq '0xFFFFF') { $fkey = "$mask|$val@$cx,$cz" }
    if ($priorKeys.ContainsKey($fkey) -or $usedThisRun.ContainsKey($fkey)) {
        $L = $ledger[$fkey]
        Write-Host ("  skip ({0,6},{1,6})  family {2}|{3} already run" -f $cx,$cz,$mask,$val) -ForegroundColor DarkGray
        if ($L -and [double]$L.BestCQ -gt 0) {
            $rows += [pscustomobject]@{
                CQ=[double]$L.BestCQ; Eff=[double]$L.Eff; Chunks=[int]$L.Chunks
                X=[int]$L.X; Z=[int]$L.Z; Seed=$L.Seed; SpotX=$cx; SpotZ=$cz
                Seeds=0; Mask=$mask; Val=$val
                Dist=[int][math]::Sqrt([double]$L.X*[double]$L.X + [double]$L.Z*[double]$L.Z)
            }
        }
        continue
    }
    $usedThisRun[$fkey] = 1
    $a = $line -replace '^\s*slime_gpu\.exe\s*',''
    if ($Floor -gt 0) {
        $a = $a -replace '--record-floor\s+\d+', "--record-floor $Floor"
        $a = $a -replace '--seeds-floor\s+\d+',  "--seeds-floor $Floor"
    }
    $eligible += [pscustomobject]@{ Cx=$cx; Cz=$cz; Out=$out; Mask=$mask; Val=$val; FKey=$fkey; A=$a }
}

# ---- PHASE 2: hunt + score + climb each eligible spot, ONE-AHEAD PIPELINED.
#
# Serially, each spot cost: hunt (GPU, via the worker) -> score (CPU,
# slime_refine) -> maybe climb (GPU again) -> ledger update. Profiling
# measured ~8.6% of a cycle's wall time as pure orchestration gaps between
# GPU work - this is exactly that gap: the moment a spot's hunt is known to
# have found something, spot N+1's hunt is sent to the worker RIGHT AWAY
# (fire-and-forget write, sentinel read deferred), and spot N's CPU-only
# slime_refine scoring runs as a background process WHILE the GPU is already
# working on N+1. $pending carries the in-flight spot across loop iterations.
#
# Climbing (--climb-scan) is itself GPU work on the SAME worker, so it can
# never overlap with N+1's hunt (one CUDA context, one job at a time) - if a
# spot needs climbing while N+1 is still in flight, its sentinel is drained
# first (usually near-instant, since it had a head start during scoring) so
# the worker is free again. This only forfeits overlap for THAT spot's
# climb, not the hunt/score overlap that already happened.
$pending = $null
for ($idx = 0; $idx -lt $eligible.Count; $idx++) {
    $c = $eligible[$idx]
    $cx = $c.Cx; $cz = $c.Cz; $out = $c.Out; $mask = $c.Mask; $val = $c.Val; $fkey = $c.FKey; $a = $c.A
    $num = $idx + 1

    if ($pending -and $pending.Idx -eq $idx) {
        $before = $pending.Before
        if (-not $pending.SentinelRead -and -not (Wait-SlimeWorker $script:worker)) {
            Write-Host "  worker died mid-flight - falling back to per-process spawning for the rest of this run" -ForegroundColor Red
            Stop-SlimeWorker $script:worker
            $script:worker = $null
            Invoke-Hunt $a $out $Seconds $before
        }
    } else {
        $before = SeedCount $out
        # Early abort: seed yield is LINEAR in time (measured: 25/61/91/113/134/153
        # cumulative at 10s steps on a live spot), so a spot with nothing at 5s is
        # not "warming up" - it is dead, and the remaining budget is pure waste.
        # On this hardware --give-up-after (20M seeds) already judges a dead spot
        # in well under a second, so this is enforced inside the hunt itself now.
        Invoke-Hunt $a $out $Seconds $before
    }
    $pending = $null

    $found = (SeedCount $out) - $before
    if ($found -le 0) {
        Write-Host ("[{0,2}/{1}] ({2,6},{3,6})  no seeds" -f $num,$Top,$cx,$cz) -ForegroundColor DarkGray
        # ledger the dead pass too, or this family gets re-hunted every cycle
        if ($ledger.ContainsKey($fkey)) { $ledger[$fkey].Times = [int]$ledger[$fkey].Times + 1 }
        else { $ledger[$fkey] = [pscustomobject]@{ Key=$fkey; Mask=$mask; Val=$val; SpotX=$cx; SpotZ=$cz
            BestCQ=0; Eff=0; Chunks=0; X=0; Z=0; Seed=""; Times=1 } }
        continue
    }

    # Prefetch spot N+1's hunt now, before this spot's scoring - see the
    # block comment above. A dead spot (above) never reaches here, which is
    # fine: there is no CPU work after a dead spot worth overlapping against.
    if ($script:worker -and ($idx + 1) -lt $eligible.Count) {
        $nc = $eligible[$idx + 1]
        $nBefore = SeedCount $nc.Out
        if (Send-SlimeWorker $script:worker "$($nc.A) --time-limit-ms $($Seconds * 1000)") {
            $pending = @{ Idx = $idx + 1; Before = $nBefore; SentinelRead = $false }
        } else {
            Write-Host "  worker died - falling back to per-process spawning for the rest of this run" -ForegroundColor Red
            Stop-SlimeWorker $script:worker
            $script:worker = $null
        }
    }

    # ---- score immediately, in real cq (only this hunt's new seeds) ----
    $sum = Join-Path $root ("main\work\cq_{0}_{1}.csv" -f $cx,$cz)
    $tmpNew = Join-Path $root ("main\work\new_{0}_{1}.csv" -f $cx,$cz)
    $scoreSrc = NewSeedsFile $out $before $tmpNew
    if (-not $scoreSrc) { $scoreSrc = $out }
    # which 20-bit family did this spot's hits come from? (see -RichTop)
    $richVal = ""; $richHits = 0
    $rg = @(SeedList $scoreSrc) | Group-Object { [int64]$_ -band 0xFFFFF } | Sort-Object Count -Descending | Select-Object -First 1
    if ($rg) { $richVal = '0x{0:X5}' -f [int64]$rg.Name; $richHits = $rg.Count }
    $ra = @("--seeds",$scoreSrc,"--center-x",$cx,"--center-z",$cz,"--radius",$Radius,
            "--csv",$sum,"--quiet","--family",("pipe_{0}_{1}" -f $cx,$cz),"--no-images","--no-logs")
    if ($pending) {
        # A hunt is in flight on the worker - score in the BACKGROUND so this
        # CPU-only step overlaps the GPU's time instead of sitting after it.
        $scoreProc = Start-Process -FilePath (Join-Path $root "slime_refine.exe") -ArgumentList $ra `
                     -WorkingDirectory $root -PassThru @hideWin
        $scoreProc.WaitForExit()
    } else {
        & (Join-Path $root "slime_refine.exe") @ra *> $null
    }
    if (-not (Test-Path $sum)) {
        Write-Host ("[{0,2}/{1}] ({2,6},{3,6})  {4} seeds, nothing scored" -f $num,$Top,$cx,$cz,$found) -ForegroundColor DarkGray
        continue
    }
    $best = Import-Csv $sum | Sort-Object { [double]$_.cq } -Descending | Select-Object -First 1
    if (-not $best) { continue }

    # Sweep the best seed's high bits before moving on. Measured: at
    # (-1008,-8528) the best SEED scored 64.06, but a high-bit VARIANT of a
    # different seed there reached 64.2 - the sweep is 8192 near-free layouts
    # and can beat what the hunt itself found. Only the best seed is swept:
    # variation count tracked base cq almost perfectly in that test, so
    # sweeping the losers buys nothing.
    #
    # GPU-first: slime_gpu --climb-scan does the identical 8192-variant sweep in
    # 0.2s where slime_refine --climb takes 23.4s (measured, same seed/spot) -
    # the CPU climb was 35% of a full pipeline run. The GPU pass is chunk-
    # aligned, so its top few variants go through slime_refine for the real
    # block-precision number; that GPU->refine chain reproduced 66.04 and 64.17
    # exactly when it was validated earlier.
    if (-not $NoClimb -and [double]$best.cq -ge $ClimbMinCQ) {
        # WIDE sweep, bits 24-47: 16.7M variants in ~5s (measured) vs 8192 in
        # 0.2s for the old 35-47 window - 2048x the coverage for +5s. This
        # exhaustively retires the best seed's entire low-24-bit CORE: every
        # seed sharing its low 24 bits is now fully analyzed, deterministically,
        # which is what makes the family ledger's "mined" call meaningful.
        # (Hunting covers ~0.3% of a family per 12s at the measured 4M seeds/s;
        # the sweep is the only exhaustive instrument in the toolbox.)
        #
        # If spot N+1's hunt is still in flight on the worker, it must finish
        # (or be drained) before the worker is free to climb THIS spot - see
        # the block comment at the top of Phase 2.
        if ($pending -and -not $pending.SentinelRead) {
            if (-not (Wait-SlimeWorker $script:worker)) {
                Write-Host "  worker died mid-flight - falling back to per-process spawning for the rest of this run" -ForegroundColor Red
                Stop-SlimeWorker $script:worker
                $script:worker = $null
                Invoke-Hunt $eligible[$pending.Idx].A $eligible[$pending.Idx].Out $Seconds $pending.Before
            }
            $pending.SentinelRead = $true
        }
        $best = Climb-Seed $best $cx $cz 24 24 "climb"
        # DEEP CLIMB - only for a seed with a real shot at the record. The standard
        # 24-bit window tops out at about +2.1 cq; re-climbing its result again
        # gains nothing (measured on 5 seeds: 0 improvements). A 16x wider window
        # (bits 20-47, 268M variants, still outside the family mask) found what it
        # could not: 65.55 -> 66.31, 64.71 -> 65.05, 64.00 -> 64.44, 3 of 5 seeds,
        # at ~90-200 s each on the laptop. Worth that only near the record.
        if ([double]$best.cq -ge $DeepClimbMinCQ) { $best = Climb-Seed $best $cx $cz 20 28 "deep climb" }
    }

    # Import-Csv yields STRINGS. In PowerShell "5426" * 5426 is string
    # repetition, not arithmetic, so these must be cast before any math or the
    # multiply silently builds a megabyte-long string and then fails to convert.
    $bx = [double]$best.x; $bz = [double]$best.z
    $rows += [pscustomobject]@{
        CQ=[double]$best.cq; Eff=[double]$best.eff_pct; Chunks=[int]$best.chunks_at_best_blocks
        X=[int]$bx; Z=[int]$bz; Seed=$best.seed; SpotX=$cx; SpotZ=$cz
        Seeds=$found; Mask=$mask; Val=$val
        Dist=[int][math]::Sqrt($bx*$bx + $bz*$bz)
        RichVal=$richVal; RichHits=$richHits
    }
    # picture only for results actually worth looking at
    if (-not $NoImages -and [double]$best.cq -ge $ImageMinCQ) {
        SaveImage $best.seed $cx $cz ("pipe_{0}_{1}" -f $cx,$cz) $Radius $root
    }
    # peak settled for this seed - file it if it is 64+
    if ([double]$best.cq -ge 64.0) {
        ArchiveResult $best.cq $best.seed $cx $cz ("pipe_{0}_{1}" -f $cx,$cz) $Radius $root "$mask|$val"
        Write-Host ("      kept -> main\records\{0}\" -f [math]::Floor([double]$(if ($pb) { $pb.cq } else { $best.cq }))) -ForegroundColor DarkCyan
    }
    $col = if ([double]$best.cq -gt $Record) { "Magenta" } elseif ([double]$best.cq -ge 64) { "Green" } else { "Gray" }
    Write-Host ("[{0,2}/{1}] ({2,6},{3,6})  {4,3} seeds -> best {5} cq  {6}% pack  {7}c  ({8},{9})" `
        -f $num,$Top,$cx,$cz,$found,$best.cq,$best.eff_pct,$best.chunks_at_best_blocks,$best.x,$best.z) -ForegroundColor $col

    # ledger update: count the pass; a pass that did not raise BestCQ moves the
    # family toward "mined" (skipped at Times >= 2 unless it improved)
    if ($ledger.ContainsKey($fkey)) {
        $L = $ledger[$fkey]
        if ([double]$best.cq -gt [double]$L.BestCQ) {
            # improvement resets the clock - a family still climbing is not mined
            $L.BestCQ = $best.cq; $L.Eff = $best.eff_pct; $L.Chunks = $best.chunks_at_best_blocks
            $L.X = $best.x; $L.Z = $best.z; $L.Seed = $best.seed; $L.Times = 1
        } else { $L.Times = [int]$L.Times + 1 }
    } else {
        $ledger[$fkey] = [pscustomobject]@{ Key=$fkey; Mask=$mask; Val=$val; SpotX=$cx; SpotZ=$cz
            BestCQ=$best.cq; Eff=$best.eff_pct; Chunks=$best.chunks_at_best_blocks
            X=$best.x; Z=$best.z; Seed=$best.seed; Times=1 }
    }
}

if ($rows.Count -eq 0) {
    Write-Host "no spot produced a scoreable seed" -ForegroundColor Yellow
    Stop-SlimeWorker $worker
    # Still save the ledger (the dead families were logged above - skipping this made the
    # next cycle re-hunt them) and an EMPTY pipeline.csv (record_cycle reads it; leaving the
    # previous cycle's file in place made this cycle report that cycle's best as its own).
    $ledger.Values | Export-Csv -Path $ledgerPath -NoTypeInformation
    Set-Content -Path main\pipeline.csv -Value '"CQ","Eff","Chunks","X","Z","Seed","SpotX","SpotZ","Seeds","Mask","Val","Dist"' -Encoding ascii
    Get-ChildItem (Join-Path $root "main\work") -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $script:runStart } | Remove-Item -Force -ErrorAction SilentlyContinue
    exit 0
}
$rows = $rows | Sort-Object CQ -Descending

# ---- RICH-FAMILY EXHAUST: walk every seed of the family the hits came from -------
if ($RichTop -gt 0 -and $RichSeconds -gt 0) {
    $outOf = @{}; foreach ($e in $eligible) { $outOf["$($e.Cx)_$($e.Cz)"] = $e.Out }
    $richTargets = @($rows | Where-Object { [int]$_.Seeds -gt 0 -and [int]$_.RichHits -ge $RichMinHits -and [double]$_.CQ -ge $RichMinCQ } |
                     Sort-Object { [int]$_.RichHits } -Descending | Select-Object -First $RichTop)
    foreach ($r in $richTargets) {
        $rkey = "0xFFFFF|$($r.RichVal)@$($r.SpotX),$($r.SpotZ)"
        if ($priorKeys.ContainsKey($rkey) -or $usedThisRun.ContainsKey($rkey)) {
            Write-Host ("  skip rich ({0},{1})  family {2} already exhausted" -f $r.SpotX,$r.SpotZ,$r.RichVal) -ForegroundColor DarkGray; continue }
        $usedThisRun[$rkey] = 1
        $out = $outOf["$($r.SpotX)_$($r.SpotZ)"]; if (-not $out) { continue }
        Write-Host ("rich family ({0},{1})  {2}: {3} of the spot's {4} triage seeds -> all 2^28 seeds, floor {5}, {6}s" `
            -f $r.SpotX,$r.SpotZ,$r.RichVal,$r.RichHits,$r.Seeds,$RichFloor,$RichSeconds) -ForegroundColor Cyan
        $a = "--seed-count 0 --center-x $($r.SpotX) --center-z $($r.SpotZ) --m-chunks 24 --fix-mask 0xFFFFF --fix-val $($r.RichVal) " +
             "--record-floor $RichFloor --seeds-floor $RichFloor --report-every 1000000000 --give-up-after 0 --enumerate --enum-start 0 --seeds-out $out"
        $before = SeedCount $out
        Invoke-Hunt $a $out $RichSeconds $before
        $found = (SeedCount $out) - $before
        $scored = @()
        if ($found -gt 0) {
            $sum = Join-Path $root ("main\work\rich_{0}_{1}.csv" -f $r.SpotX,$r.SpotZ)
            $tmpR = Join-Path $root ("main\work\rnew_{0}_{1}.csv" -f $r.SpotX,$r.SpotZ)
            $rSrc = NewSeedsFile $out $before $tmpR
            if (-not $rSrc) { $rSrc = $out }
            $ra = @("--seeds",$rSrc,"--center-x",$r.SpotX,"--center-z",$r.SpotZ,"--radius",$Radius,
                    "--csv",$sum,"--quiet","--family",("pipe_{0}_{1}" -f $r.SpotX,$r.SpotZ),"--no-images","--no-logs")
            & (Join-Path $root "slime_refine.exe") @ra *> $null
            if (Test-Path $sum) { $scored = @(Import-Csv $sum | Sort-Object { [double]$_.cq } -Descending) }
        }
        $rb = if ($scored.Count) { $scored[0] } else { $null }
        # ledger the exhaust: every seed of this family at this spot has now been checked
        $ledger[$rkey] = [pscustomobject]@{ Key=$rkey; Mask='0xFFFFF'; Val=$r.RichVal; SpotX=$r.SpotX; SpotZ=$r.SpotZ
            BestCQ=$(if ($rb) { $rb.cq } else { 0 }); Eff=$(if ($rb) { $rb.eff_pct } else { 0 }); Chunks=$(if ($rb) { $rb.chunks_at_best_blocks } else { 0 })
            X=$(if ($rb) { $rb.x } else { 0 }); Z=$(if ($rb) { $rb.z } else { 0 }); Seed=$(if ($rb) { $rb.seed } else { "" }); Times=1 }
        if (-not $rb) { Write-Host "      no layout >= $RichFloor chunks anywhere in the family" -ForegroundColor DarkGray; continue }
        Write-Host ("      family holds {0} layouts >= {1}; best {2} cq (triage had {3})" -f $scored.Count, $RichFloor, $rb.cq, $r.CQ) -ForegroundColor $(if ([double]$rb.cq -gt $r.CQ) { 'Yellow' } else { 'DarkGray' })
        # archive every 66+ layout the family holds (the best first), not only the best
        $seen = @{}
        foreach ($s in ($scored | Where-Object { [double]$_.cq -ge 66.0 } | Select-Object -First 5)) {
            if ($seen.ContainsKey("$($s.x),$($s.z),$($s.cq)")) { continue }; $seen["$($s.x),$($s.z),$($s.cq)"] = 1
            ArchiveResult $s.cq $s.seed $r.SpotX $r.SpotZ ("pipe_{0}_{1}" -f $r.SpotX,$r.SpotZ) $Radius $root $rkey
        }
        if ([double]$rb.cq -gt $r.CQ) {
            if ([double]$rb.cq -lt 66.0 -and [double]$rb.cq -ge 64.0) { ArchiveResult $rb.cq $rb.seed $r.SpotX $r.SpotZ ("pipe_{0}_{1}" -f $r.SpotX,$r.SpotZ) $Radius $root $rkey }
            $r.CQ = [double]$rb.cq; $r.Eff = [double]$rb.eff_pct; $r.Chunks = [int]$rb.chunks_at_best_blocks
            $r.X = [int]$rb.x; $r.Z = [int]$rb.z; $r.Seed = $rb.seed
            $r.Dist = [int][math]::Sqrt([double]$rb.x*[double]$rb.x + [double]$rb.z*[double]$rb.z)
        }
    }
    $rows = $rows | Sort-Object CQ -Descending
}

# ---- RECORD PUSH: second, floor-raised hunt on the leaders ------------------
# Off while the rich-family exhaust is on: it hunts the same family more precisely.
if ($PushTop -gt 0 -and $PushSeconds -gt 0 -and $RichTop -le 0) {
    $cmdLines = Get-Content $Commands | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith('#') }
    $pushTargets = @($rows | Select-Object -First $PushTop)
    # Anchor first: it is the only family that reliably yields 70c draws, so it
    # gets budget before any triage-ranked spot. Synthesised as a row (with a
    # hand-built command line, since the anchor need not appear in this scan's
    # commands file at all) and prepended.
    if (-not $NoAnchor -and $AnchorSpot -match '^\s*(-?\d+)\s*,\s*(-?\d+)\s*$') {
        $ax = [int]$Matches[1]; $az = [int]$Matches[2]
        $aOut = "main/seeds/{0}_{1}.csv" -f $ax,$az
        $aLine = "slime_gpu.exe --seed-count 0 --center-x $ax --center-z $az --m-chunks 24 " +
                 "--fix-mask $AnchorMask --fix-val $AnchorVal --record-floor 70 --seeds-floor 70 " +
                 "--give-up-after 0 --report-every 900000000 --seeds-out $aOut"
        $cmdLines = @($aLine) + $cmdLines
        $known = $rows | Where-Object { $_.SpotX -eq $ax -and $_.SpotZ -eq $az } | Select-Object -First 1
        $aRow = if ($known) { $known } else {
            [pscustomobject]@{ CQ=0.0; Eff=0.0; Chunks=0; X=$ax; Z=$az; Seed=""; SpotX=$ax; SpotZ=$az
                Seeds=0; Mask=$AnchorMask; Val=$AnchorVal
                Dist=[int][math]::Sqrt([double]($ax*$ax) + [double]($az*$az)) }
        }
        if (-not $known) { $rows = @($rows) + $aRow }
        $pushTargets = @($aRow) + @($pushTargets | Where-Object { -not ($_.SpotX -eq $ax -and $_.SpotZ -eq $az) })
        Write-Host ("anchor: ({0},{1}) family {2}|{3} pushed first" -f $ax,$az,$AnchorMask,$AnchorVal) -ForegroundColor Magenta
    }
    $pushed = @()
    foreach ($r in $pushTargets) {
        $line = $cmdLines | Where-Object { $_ -match ('--center-x\s+' + [regex]::Escape($r.SpotX) + '\s') -and
                                           $_ -match ('--center-z\s+' + [regex]::Escape($r.SpotZ) + '\s') } | Select-Object -First 1
        if (-not $line) { continue }
        if ($line -notmatch '--seeds-out\s+(\S+)') { continue }; $out = $Matches[1]
        $isAnchorRow = (-not $NoAnchor) -and ($AnchorSpot -match '^\s*(-?\d+)\s*,\s*(-?\d+)\s*$') -and
                       ($r.SpotX -eq [int]$Matches[1]) -and ($r.SpotZ -eq [int]$Matches[2])
        if (-not $isAnchorRow -and [double]$r.CQ -lt $PushMinCQ) {
            Write-Host ("  skip push ({0},{1})  triage {2} cq < {3} - never reaches floor {4}" `
                -f $r.SpotX,$r.SpotZ,$r.CQ,$PushMinCQ,$PushFloor) -ForegroundColor DarkGray
            continue
        }
        # FAMILY SWEEP before the push. The scan derives ONE family per spot and
        # hunts it; the sweep measures ALL 2^bits families at that spot in ~9s
        # and picks the best by hit rate. Validated at the record spot: the
        # family the 66.04 came from ranks 1 of 16384 (+13.2 sd), and ~16000
        # families there produce nothing at all - so which family gets hunted
        # matters enormously and the derivation's single pick is not guaranteed
        # best. Ranked by HITS, not max cq: max-of-sample is an order statistic
        # that picked a family capping at 64.40 over the one that makes 66.04.
        $useMask = $r.Mask; $useVal = $r.Val
        # Never sweep the anchor: its 16384 families were already swept
        # exhaustively and 0x70802 came out #1, so re-deriving that every cycle
        # is ~15s of known-answer.
        $isAnchor = ($AnchorSpot -match '^\s*(-?\d+)\s*,\s*(-?\d+)\s*$') -and
                    ($r.SpotX -eq [int]$Matches[1]) -and ($r.SpotZ -eq [int]$Matches[2])
        $useMask = if ($ForceMask) { $ForceMask } else { $r.Mask }
        # Under -ForceMask the val was already chosen at TRIAGE (best never-run
        # family under the forced mask). Re-sweeping here could switch to a val
        # some earlier run already used, breaking never-run-twice - so keep it.
        if (-not $NoSweep -and -not $isAnchor -and $useMask -ne "-" -and -not $ForceMask) {
            $sf = Join-Path $root ("main\work\sweep_{0}_{1}.csv" -f $r.SpotX,$r.SpotZ)
            & (Join-Path $root "hotspot_scan.exe") --family-sweep --center-x $r.SpotX --center-z $r.SpotZ `
                --sweep-mask $useMask --sweep-n 16384 --sweep-seeds 400000 --sweep-floor $SweepFloor `
                --rng-seed $script:sweepRng `
                --sweep-out $sf *> $null
            if (Test-Path $sf) {
                # NOT $top - PowerShell is case-insensitive, so that silently
                # aliases the [int]$Top parameter and the assignment throws,
                # leaving the push on the un-swept family.
                $swBest = Import-Csv $sf | Select-Object -First 1
                if ($swBest -and [int]$swBest.hits -gt 0) {
                    Write-Host ("      sweep: family {0} -> {1} ({2} hits, best {3} cq in sample)" `
                        -f $r.Val,$swBest.val,$swBest.hits,$swBest.best_cq) -ForegroundColor Cyan
                    $useVal = $swBest.val
                }
            }
        }
        Write-Host ("push ({0},{1})  floor {2}, {3}s, family {4}..." -f $r.SpotX,$r.SpotZ,$PushFloor,$PushSeconds,$useVal) -ForegroundColor Cyan
        $a = $line -replace '^\s*slime_gpu\.exe\s*',''
        $a = $a -replace '--record-floor\s+\d+', "--record-floor $PushFloor"
        $a = $a -replace '--seeds-floor\s+\d+',  "--seeds-floor $PushFloor"
        $a = $a -replace '--fix-val\s+\S+',      "--fix-val $useVal"
        # Apply the forced mask to the hunt itself, not just the sweep - the
        # sweep picked $useVal from THIS mask's 16384 vals, so the hunt has to
        # use the same mask or the val means something else entirely. Placed
        # before the enum-progress filename is derived so the key matches.
        # NEVER the anchor: it exists to push one specific known record family
        # (0xFDE0F|0x70802). Forcing another mask onto it silently re-masks its
        # val - e.g. 0x70802 & 0xEF70F = 0x60002 - hunting a meaningless family.
        if ($ForceMask -and -not $isAnchor) { $a = $a -replace '--fix-mask\s+\S+', "--fix-mask $ForceMask" }
        # EXHAUSTIVE PUSH. Only the low 48 bits of a seed reach the slime
        # function, so a b-bit --fix-mask is a FINITE family of exactly 2^(48-b)
        # layouts. Random sampling draws WITH replacement: ~4.6F draws for 99%
        # coverage, and it can never prove a family is empty. --enumerate walks
        # each layout exactly once at ~97.5% of random throughput (measured
        # 7.03M vs 7.21M seeds/s once the scatter moved into the kernel), so it
        # is ~4.5x more efficient per unit of coverage AND converges on proof.
        #
        # RESUME IS THE WHOLE POINT: enumeration restarts at index 0 every run,
        # and the anchor family is pushed EVERY cycle, so without --enum-start
        # this would re-test one identical prefix forever - strictly worse than
        # random. slime_gpu checkpoints its index every 64 batches (it gets
        # killed on the timeout, so it cannot checkpoint at exit); resuming from
        # the last checkpoint re-tests a few seconds at worst, never skips.
        $enumDir = Join-Path $root "main\enum"
        if (-not (Test-Path $enumDir)) { New-Item -ItemType Directory -Force -Path $enumDir | Out-Null }
        $emask = if ($a -match '--fix-mask\s+(\S+)') { $matches[1] } else { "nomask" }
        # RELATIVE and UNQUOTED on purpose. The persistent worker tokenizes spot
        # lines on plain whitespace and does not strip quotes (its own comment:
        # "never quoted, never spaced within one value"), so a quoted path
        # reaches fopen with literal quote characters and fails - silently,
        # because the writer guards on `if (pf)`. This path has no spaces and
        # the worker runs with $root as its working directory.
        $ef = 'main\enum\{0}_{1}_{2}_{3}.txt' -f $r.SpotX, $r.SpotZ, $emask, $useVal
        $estart = 0
        $efFull = Join-Path $root $ef
        if (Test-Path $efFull) {
            $raw = (Get-Content $efFull -Raw).Trim()
            if ($raw -match '^\d+$') { $estart = $raw }
        }
        $a = "$a --enumerate --enum-start $estart --enum-progress $ef"
        if ($estart -ne 0) { Write-Host ("      resuming enumeration at {0}" -f $estart) -ForegroundColor DarkGray }
        $before = SeedCount $out
        Invoke-Hunt $a $out $PushSeconds $before
        $found = (SeedCount $out) - $before
        if ($found -le 0) { Write-Host "      nothing above floor $PushFloor" -ForegroundColor DarkGray; continue }
        # score the whole file (cheap, 0.02 s/seed) and take the overall best
        $sum = Join-Path $root ("main\work\push_{0}_{1}.csv" -f $r.SpotX,$r.SpotZ)
        $tmpP = Join-Path $root ("main\work\pnew_{0}_{1}.csv" -f $r.SpotX,$r.SpotZ)
        $pSrc = NewSeedsFile $out $before $tmpP
        if (-not $pSrc) { $pSrc = $out }
        $ra = @("--seeds",$pSrc,"--center-x",$r.SpotX,"--center-z",$r.SpotZ,"--radius",$Radius,
                "--csv",$sum,"--quiet","--family",("pipe_{0}_{1}" -f $r.SpotX,$r.SpotZ),"--no-images","--no-logs")
        & (Join-Path $root "slime_refine.exe") @ra *> $null
        if (-not (Test-Path $sum)) { continue }
        $pb = Import-Csv $sum | Sort-Object { [double]$_.cq } -Descending | Select-Object -First 1
        # Push seeds were never climbed, so they lost to the spot's already-climbed
        # triage best every time (cycle #404: 5 pushes, 0 improvements). Same
        # climbs as triage: standard at -ClimbMinCQ, deep at -DeepClimbMinCQ.
        if ($pb -and -not $NoClimb -and [double]$pb.cq -ge $ClimbMinCQ) {
            $pb = Climb-Seed $pb $r.SpotX $r.SpotZ 24 24 "push climb"
            if ([double]$pb.cq -ge $DeepClimbMinCQ) { $pb = Climb-Seed $pb $r.SpotX $r.SpotZ 20 28 "push deep climb" }
        }
        if ($pb -and [double]$pb.cq -gt $r.CQ) {
            Write-Host ("      push: {0} -> {1} cq" -f $r.CQ,$pb.cq) -ForegroundColor Yellow
            if (-not $NoImages -and [double]$pb.cq -ge $ImageMinCQ) {
                SaveImage $pb.seed $r.SpotX $r.SpotZ ("pipe_{0}_{1}" -f $r.SpotX,$r.SpotZ) $Radius $root
            }
            if ([double]$pb.cq -ge 64.0) {
                ArchiveResult $pb.cq $pb.seed $r.SpotX $r.SpotZ ("pipe_{0}_{1}" -f $r.SpotX,$r.SpotZ) $Radius $root "$useMask|$useVal"
                Write-Host ("      kept -> main\records\{0}\" -f [math]::Floor([double]$(if ($pb) { $pb.cq } else { $best.cq }))) -ForegroundColor DarkCyan
            }
            $r.CQ = [double]$pb.cq; $r.Eff = [double]$pb.eff_pct; $r.Chunks = [int]$pb.chunks_at_best_blocks
            $r.X = [int]$pb.x; $r.Z = [int]$pb.z; $r.Seed = $pb.seed
            $r.Dist = [int][math]::Sqrt([double]$pb.x*[double]$pb.x + [double]$pb.z*[double]$pb.z)
        }
        $pushed += $r
    }
    $rows = $rows | Sort-Object CQ -Descending
}
Stop-SlimeWorker $worker

$log = @("HUNT PIPELINE  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
         "source: $Commands",
         "${Seconds}s/spot, top $Top, hunt floor $Floor, refine radius $Radius",
         "Ranked by REAL cq (packing x count), not seed volume. Record: $Record cq","",
         "     cq   pack    c   seeds   position            dist    spot              seed")
foreach ($r in $rows) {
    $log += ("  {0,6}  {1,5}%  {2,3}   {3,5}   ({4,7},{5,7})  {6,7}   ({7,6},{8,6})  {9}" -f `
        $r.CQ,$r.Eff,$r.Chunks,$r.Seeds,$r.X,$r.Z,$r.Dist,$r.SpotX,$r.SpotZ,$r.Seed)
}
$log += ""
$b = $rows[0]
if ($b.CQ -gt $Record) {
    $log += ("*** NEW RECORD  {0} cq  at ({1},{2})  seed {3}  /tp {1} ~ {2} ***" -f $b.CQ,$b.X,$b.Z,$b.Seed)
} else {
    $log += ("best {0} cq at ({1},{2}), short of {3}." -f $b.CQ,$b.X,$b.Z,$Record)
    $log += "cq = chunks x packing. On ordinary spots packing falls with count and the"
    $log += "product peaked at 70c (94.3% @70c, 91.4% @71c). On HEAT spots the frontier"
    $log += "sits higher: the 67.24 is 72c @ 93.4%, so 71-72c draws are live targets there."
}
$log += "","Results of 64+ cq: main\records\<tier>\ (txt + png) and one row each in main\records\index.csv."
$log | Set-Content -Encoding UTF8 main\pipeline.txt
$rows | Export-Csv -Path main\pipeline.csv -NoTypeInformation
$ledger.Values | Export-Csv -Path $ledgerPath -NoTypeInformation
Write-Host ""
$log | ForEach-Object { Write-Host $_ }
Write-Host "`nwrote main\pipeline.txt" -ForegroundColor Green

# ---- tidy this run's scratch --------------------------------------------------
# Per-spot temp files (cq_/new_/tsweep_/climb_/climbcq_/push_/pnew_/img_...) only
# matter while their spot is in flight; heat mode touches ~120 new spots a cycle,
# ~5 files each, so without this main\work grows by ~600 files per cycle. Only
# files THIS run wrote are removed, and score folders it left empty.
Get-ChildItem (Join-Path $root "main\work") -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $script:runStart } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $root "main\scores") -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.CreationTime -ge $script:runStart -and -not (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
