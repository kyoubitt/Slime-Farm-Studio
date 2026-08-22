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
    [int]$MaxDist     = 10000,
    # Falls back to the old one-process-per-spot behaviour (Start-Process +
    # poll + kill). Use this if the persistent worker misbehaves; every spot
    # still runs, just ~199ms/spawn slower (measured) - the same cost this
    # was built to remove. See Start-SlimeWorker/Invoke-Hunt below.
    [switch]$NoWorker
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
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
function Invoke-ClimbScan($seedVal, $cx, $cz) {
    $argLine = "--climb-scan --seed $seedVal --center-x $cx --center-z $cz --m-chunks 6 --climb-lo 24 --climb-bits 24 --climb-top 5"
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
        --m-chunks 6 --climb-lo 24 --climb-bits 24 --climb-top 5 2>&1
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
         -WorkingDirectory $root -PassThru -WindowStyle Hidden
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $secs) {
        Start-Sleep -Milliseconds 500
        if ($sw.Elapsed.TotalSeconds -ge 5 -and ((SeedCount $out) - $before) -eq 0) { break }
    }
    if (-not $p.HasExited) { try { $p.Kill() } catch {}; $p.WaitForExit() }
}

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
}

# File a finished result into main\records\ so the good ones are not buried
# among thousands of ordinary scores. ONE flat folder, no tier split - every
# filename is prefixed with its own cq so the best results sort together and
# stay easy to scan at a glance. Only the peak position for that seed is
# kept - one txt + one png per result, no high-bit duplicates. Called after
# the best position for a seed is settled.
function ArchiveResult($cq, $seed, $cx, $cz, $family, $radius, $root) {
    $tier = [math]::Floor([double]$cq)
    if ($tier -lt 64) { return }
    $dir = Join-Path $root "main\records"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # ensure the artefacts exist (scoring runs image-free, so the png may not)
    SaveImage $seed $cx $cz $family $radius $root
    $src = Join-Path $root ("main\scores\{0}" -f $family)
    if (-not (Test-Path $src)) { return }
    $cqStr = "{0:0.00}" -f [double]$cq
    Get-ChildItem $src -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match ([regex]::Escape($seed) + '$') } |
        ForEach-Object {
            Copy-Item $_.FullName -Destination (Join-Path $dir ("{0}_{1}{2}" -f $cqStr, $seed, $_.Extension)) `
                -Force -ErrorAction SilentlyContinue
        }
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
    # mined family? keep its known best in the ranking, spend the hunt elsewhere
    $fkey = "$mask|$val"
    if ($ledger.ContainsKey($fkey) -and [int]$ledger[$fkey].Times -ge 2) {
        $L = $ledger[$fkey]
        Write-Host ("  skip ({0,6},{1,6})  family {2} mined ({3} passes, best {4})" -f $cx,$cz,$mask,$L.Times,$L.BestCQ) -ForegroundColor DarkGray
        if ([double]$L.BestCQ -gt 0) {
            $rows += [pscustomobject]@{
                CQ=[double]$L.BestCQ; Eff=[double]$L.Eff; Chunks=[int]$L.Chunks
                X=[int]$L.X; Z=[int]$L.Z; Seed=$L.Seed; SpotX=$cx; SpotZ=$cz
                Seeds=0; Mask=$mask; Val=$val
                Dist=[int][math]::Sqrt([double]$L.X*[double]$L.X + [double]$L.Z*[double]$L.Z)
            }
        }
        continue
    }
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
    $ra = @("--seeds",$scoreSrc,"--center-x",$cx,"--center-z",$cz,"--radius",$Radius,
            "--csv",$sum,"--quiet","--family",("pipe_{0}_{1}" -f $cx,$cz),"--no-images")
    if ($pending) {
        # A hunt is in flight on the worker - score in the BACKGROUND so this
        # CPU-only step overlaps the GPU's time instead of sitting after it.
        $scoreProc = Start-Process -FilePath (Join-Path $root "slime_refine.exe") -ArgumentList $ra `
                     -WorkingDirectory $root -PassThru -WindowStyle Hidden
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
        $cs = Invoke-ClimbScan $best.seed $cx $cz
        $vseeds = @()
        foreach ($ln in $cs) {
            # variant rows: "<blocks> <cq> (<x>,<z>) <seed>"
            if ($ln -match '^\s*\d+\s+[0-9.]+\s+\(\s*-?\d+,\s*-?\d+\)\s+(-?\d+)\s*$') {
                if ($Matches[1] -ne $best.seed) { $vseeds += $Matches[1] }
            }
        }
        if ($vseeds.Count -gt 0) {
            $cf = Join-Path $root ("main\work\climb_{0}_{1}.csv" -f $cx,$cz)
            [System.IO.File]::WriteAllText($cf, (($vseeds | Select-Object -Unique) -join ","))
            $csum = Join-Path $root ("main\work\climbcq_{0}_{1}.csv" -f $cx,$cz)
            $ca = @("--seeds",$cf,"--center-x",$cx,"--center-z",$cz,"--radius",$Radius,
                    "--csv",$csum,"--quiet","--family",("pipe_{0}_{1}" -f $cx,$cz),"--no-images")
            & (Join-Path $root "slime_refine.exe") @ca *> $null
            if (Test-Path $csum) {
                $vb = Import-Csv $csum | Sort-Object { [double]$_.cq } -Descending | Select-Object -First 1
                if ($vb -and [double]$vb.cq -gt [double]$best.cq) {
                    Write-Host ("      climb: {0} -> {1} cq (variant)" -f $best.cq,$vb.cq) -ForegroundColor Yellow
                    $best = $vb
                }
            }
        }
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
    }
    # picture only for results actually worth looking at
    if (-not $NoImages -and [double]$best.cq -ge $ImageMinCQ) {
        SaveImage $best.seed $cx $cz ("pipe_{0}_{1}" -f $cx,$cz) $Radius $root
    }
    # peak settled for this seed - file it if it is 64+
    if ([double]$best.cq -ge 64.0) {
        ArchiveResult $best.cq $best.seed $cx $cz ("pipe_{0}_{1}" -f $cx,$cz) $Radius $root
        Write-Host "      kept -> main\records\" -ForegroundColor DarkCyan
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
    exit 0
}
$rows = $rows | Sort-Object CQ -Descending

# ---- RECORD PUSH: second, floor-raised hunt on the leaders ------------------
if ($PushTop -gt 0 -and $PushSeconds -gt 0) {
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
        if (-not $NoSweep -and -not $isAnchor -and $r.Mask -ne "-") {
            $sf = Join-Path $root ("main\work\sweep_{0}_{1}.csv" -f $r.SpotX,$r.SpotZ)
            & (Join-Path $root "hotspot_scan.exe") --family-sweep --center-x $r.SpotX --center-z $r.SpotZ `
                --sweep-mask $r.Mask --sweep-n 16384 --sweep-seeds 400000 --sweep-floor $SweepFloor `
                --sweep-out $sf *> $null
            if (Test-Path $sf) {
                # NOT $top - PowerShell is case-insensitive, so that silently
                # aliases the [int]$Top parameter and the assignment throws,
                # leaving the push on the un-swept family.
                $swBest = Import-Csv $sf | Select-Object -First 1
                if ($swBest -and [int]$swBest.hits -gt 0 -and $swBest.val -ne $r.Val) {
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
                "--csv",$sum,"--quiet","--family",("pipe_{0}_{1}" -f $r.SpotX,$r.SpotZ),"--no-images")
        & (Join-Path $root "slime_refine.exe") @ra *> $null
        if (-not (Test-Path $sum)) { continue }
        $pb = Import-Csv $sum | Sort-Object { [double]$_.cq } -Descending | Select-Object -First 1
        if ($pb -and [double]$pb.cq -gt $r.CQ) {
            Write-Host ("      push: {0} -> {1} cq" -f $r.CQ,$pb.cq) -ForegroundColor Yellow
            if (-not $NoImages -and [double]$pb.cq -ge $ImageMinCQ) {
                SaveImage $pb.seed $r.SpotX $r.SpotZ ("pipe_{0}_{1}" -f $r.SpotX,$r.SpotZ) $Radius $root
            }
            if ([double]$pb.cq -ge 64.0) {
                ArchiveResult $pb.cq $pb.seed $r.SpotX $r.SpotZ ("pipe_{0}_{1}" -f $r.SpotX,$r.SpotZ) $Radius $root
                Write-Host "      kept -> main\records\" -ForegroundColor DarkCyan
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
    $log += "THE TARGET IS ONE FRONTIER CELL: 70 chunks at >=94.4% packing (or 71c at"
    $log += ">=93.2%). Packing falls monotonically with count - 95.9% @68c, 94.9% @69c,"
    $log += "94.3% @70c, 91.4% @71c - so count x packing peaks at exactly 70c, where the"
    $log += "record sits. More chunks is NOT progress; a better-packed 70c draw is."
}
$log += "","Per-seed logs main\scores\seeds\pipe_<x>_<z>\, images main\scores\images\, cq CSVs main\work\."
$log | Set-Content -Encoding UTF8 main\pipeline.txt
$rows | Export-Csv -Path main\pipeline.csv -NoTypeInformation
$ledger.Values | Export-Csv -Path $ledgerPath -NoTypeInformation
Write-Host ""
$log | ForEach-Object { Write-Host $_ }
Write-Host "`nwrote main\pipeline.txt" -ForegroundColor Green
