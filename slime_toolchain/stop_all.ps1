# stop_all.ps1 - stop every part of a running hunt, cleanly.
#
# Killing the cycle script alone is NOT enough: slime_gpu is launched with
# Start-Process, so it outlives its parent and keeps the GPU pinned. An orphan
# left running caused a real failure - a later scan hit
# "CUDA error: unknown error" purely because two processes were fighting for the
# device (measured: orphan holding 2.3GB at 95% util). This kills the scripts
# first (so nothing relaunches), then the workers, then verifies the GPU is
# actually idle rather than assuming it.
$ErrorActionPreference = "Continue"

# 1. scripts first - otherwise a live pipeline immediately spawns a replacement
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*record_cycle*" -or $_.CommandLine -like "*hunt_pipeline*" } |
    Where-Object { $_.ProcessId -ne $PID } |
    ForEach-Object {
        Write-Host ("stopping script pid {0}" -f $_.ProcessId) -ForegroundColor DarkGray
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Start-Sleep -Milliseconds 800

# 2. workers, repeatedly - a kill can land between one exiting and the next
#    starting, so one pass is not reliable
for ($i = 0; $i -lt 4; $i++) {
    $w = Get-Process slime_gpu,slime_refine,hotspot_scan -ErrorAction SilentlyContinue
    if (-not $w) { break }
    $w | ForEach-Object {
        Write-Host ("stopping {0} pid {1}" -f $_.Name, $_.Id) -ForegroundColor DarkGray
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800
}

# 3. verify, do not assume
$left = Get-Process slime_gpu,slime_refine,hotspot_scan -ErrorAction SilentlyContinue
if ($left) {
    Write-Host ("STILL RUNNING: {0}" -f (($left | ForEach-Object { "$($_.Name)($($_.Id))" }) -join ", ")) -ForegroundColor Red
    exit 1
}
Write-Host "all stopped" -ForegroundColor Green
try {
    $gpu = (nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader) -join ""
    Write-Host ("GPU now: {0}" -f $gpu)
} catch { }
