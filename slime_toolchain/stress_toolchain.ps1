# stress_toolchain.ps1
# One run, one file: self-tests + benchmarks + a timed stress pass for all three
# tools. Paste main\stress_report.txt back for tuning - it carries everything
# needed (GPU name, rates, per-stage timings) to spot regressions or headroom.
#
# v3: cannot hang any more.
#   * every stage runs with a hard -TimeoutSec; if it blows through, the process
#     is killed, the report says TIMEOUT, and the script moves on.
#   * stdin is redirected from an empty file, so a tool that ever falls through
#     to its "reading seeds from stdin..." path gets EOF instead of waiting for
#     a human forever. That was the old hang: the script stopped dead after the
#     slime_gpu self-test line and never wrote the report.
param([switch]$Quick)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
New-Item -ItemType Directory -Force -Path main | Out-Null
New-Item -ItemType Directory -Force -Path main\stress | Out-Null
$R = "main\stress_report.txt"
"TOOLCHAIN STRESS REPORT  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content $R
try { (nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader) | Add-Content $R }
catch { "no nvidia-smi" | Add-Content $R }
"" | Add-Content $R

$emptyIn = Join-Path $env:TEMP "slime_stress_empty.txt"
"" | Set-Content $emptyIn

function Run($label, $exe, $argList, $TimeoutSec = 180) {
    "=== $label ===" | Add-Content $R
    if (-not (Test-Path $exe)) {
        "MISSING $exe - run build.ps1" | Add-Content $R; "" | Add-Content $R
        Write-Host ("{0,-42} {1,>10}" -f $label, "MISSING") -ForegroundColor Red
        return
    }
    $so = Join-Path $env:TEMP ("slime_stress_out_{0}.txt" -f [guid]::NewGuid())
    $se = Join-Path $env:TEMP ("slime_stress_err_{0}.txt" -f [guid]::NewGuid())
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $root `
         -PassThru -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se `
         -RedirectStandardInput $emptyIn
    $done = $p.WaitForExit($TimeoutSec * 1000)
    $sw.Stop()
    if (-not $done) { try { $p.Kill() } catch {}; $p.WaitForExit() }
    foreach ($f in @($so, $se)) {
        if (Test-Path $f) { Get-Content $f | Add-Content $R; Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    if ($done) {
        "[$label took $($sw.ElapsedMilliseconds) ms]" | Add-Content $R
        Write-Host ("{0,-42} {1,8} ms" -f $label, $sw.ElapsedMilliseconds)
    } else {
        "[$label TIMED OUT after ${TimeoutSec}s - killed]" | Add-Content $R
        Write-Host ("{0,-42} {1,8}" -f $label, "TIMEOUT") -ForegroundColor Yellow
    }
    "" | Add-Content $R
}

# --- correctness first: a fast stress result on a broken build is worthless ---
Run "hotspot_scan self-test"  ".\hotspot_scan.exe" @("--self-test") 120
Run "slime_gpu self-test"     ".\slime_gpu.exe"    @("--self-test") 120
Run "slime_refine self-test"  ".\slime_refine.exe" @("--self-test") 120

# --- hotspot_scan: pass 1 throughput ---
Run "hotspot_scan bench" ".\hotspot_scan.exe" `
    @("--bench","--center-x","2000","--center-z","8544","--range","40","--bench-locs","3") 180

# --- hotspot_scan: pass 2 cost on the known-good spot. Budgets are FIXED so
#     runs stay comparable across builds; adaptive sizing would hide regressions.
$checkN = if ($Quick) { "8000000" } else { "32000000" }
$scoreN = if ($Quick) { "32000000" } else { "128000000" }
Run "hotspot_scan check (fixed budgets)" ".\hotspot_scan.exe" `
    @("--check","--center-x","2000","--center-z","8544",
      "--big-n",$checkN,"--big-n-min",$checkN,
      "--measure-n",$checkN,"--measure-n-min",$checkN,
      "--score-n",$scoreN,"--score-n-min",$scoreN) 600

# --- slime_gpu: raw hunt throughput, unconstrained and masked. record-floor 99
#     is unreachable on purpose: this measures pure throughput with no file I/O.
function HuntFor($label, $extra, $secs = 30) {
    "=== $label ===" | Add-Content $R
    $log = "main\stress\$($label -replace '[^a-zA-Z0-9]','_').txt"
    $args = "--seed-count 0 --center-x 2000 --center-z 8544 --m-chunks 24 " +
            "--record-floor 99 --report-every 100000000 $extra"
    $p = Start-Process -FilePath ".\slime_gpu.exe" -ArgumentList $args -WorkingDirectory $root `
         -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardInput $emptyIn
    Start-Sleep $secs
    if (-not $p.HasExited) { try { $p.Kill() } catch {}; $p.WaitForExit() }
    if (Test-Path $log) { Get-Content $log -Tail 3 | Add-Content $R }
    "" | Add-Content $R
    Write-Host ("{0,-42} {1,8} s" -f $label, $secs)
}
$hs = if ($Quick) { 10 } else { 30 }
HuntFor "slime_gpu hunt unmasked" "" $hs
HuntFor "slime_gpu hunt masked"   "--fix-mask 0xFFFFF --fix-val 0x72902" $hs

# --- slime_refine: batch scoring + a climb, both timed. --no-images keeps
#     this measuring the scorer, not the PNG encoder.
"-8009923951419553313,1157096422294587871,5049663348150839554,2884686160915278082,2452809435317741826,-4777489624898000638," |
    Set-Content main\stress\stress_seeds.csv
Run "slime_refine 6 seeds fine" ".\slime_refine.exe" `
    @("--seeds","main\stress\stress_seeds.csv","--center-x","3680","--center-z","6992",
      "--radius","3","--quiet","--family","stress","--no-images") 300
Run "slime_refine climb (high-bit neighbor sweep)" ".\slime_refine.exe" `
    @("--seeds","main\stress\stress_seeds.csv","--center-x","3680","--center-z","6992",
      "--radius","3","--climb","--climb-recurse","--quiet","--family","stress","--no-images") 600
# one image so a broken PNG encoder shows up here and not 200 seeds later
Run "slime_refine 1 seed + image" ".\slime_refine.exe" `
    @("--seeds","main\stress\stress_seeds.csv","--center-x","3680","--center-z","6992",
      "--radius","1","--quiet","--family","stress") 300

Remove-Item $emptyIn -Force -ErrorAction SilentlyContinue
"DONE. Send main\stress_report.txt back for tuning." | Add-Content $R
Write-Host "`nwrote $R" -ForegroundColor Green
