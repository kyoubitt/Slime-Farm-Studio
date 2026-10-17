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
# Runs under Windows PowerShell 5.1 and under PowerShell 7 (pwsh) on Linux. Only real launches of the
# hunt scripts are matched (-File ...<script>.ps1), never an editor or a grep that mentions the name.
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows
$scriptRe = '-File\s+"?[^"]*\b(record_cycle|hunt_pipeline|predict_cycle|phase_spots|best_family)\.ps1'
# Tool processes. On Linux the name is the launched file name cut to 15 characters
# ("slime_refine.exe" shows as "slime_refine.ex"), so match by prefix.
$toolRe = '^(slime_gpu|slime_refine|hotspot_scan|phase_prepass|afk_rescan|geo_rank)'
function Get-Tools { Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $toolRe } }

# 1. scripts first - otherwise a live pipeline immediately spawns a replacement
$scripts = if ($onWindows) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.CommandLine -match $scriptRe } | ForEach-Object { $_.ProcessId }
} else {
    Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match $scriptRe } | ForEach-Object { $_.Id }
}
$scripts | Where-Object { $_ -ne $PID } | ForEach-Object {
    Write-Host ("stopping script pid {0}" -f $_) -ForegroundColor DarkGray
    Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 800

# 2. workers, repeatedly - a kill can land between one exiting and the next
#    starting, so one pass is not reliable
for ($i = 0; $i -lt 4; $i++) {
    $w = Get-Tools
    if (-not $w) { break }
    $w | ForEach-Object {
        Write-Host ("stopping {0} pid {1}" -f $_.Name, $_.Id) -ForegroundColor DarkGray
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800
}

# 3. verify, do not assume
$left = Get-Tools
if ($left) {
    Write-Host ("STILL RUNNING: {0}" -f (($left | ForEach-Object { "$($_.Name)($($_.Id))" }) -join ", ")) -ForegroundColor Red
    exit 1
}
Write-Host "all stopped" -ForegroundColor Green
try {
    $gpu = (nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader) -join ""
    Write-Host ("GPU now: {0}" -f $gpu)
} catch { }
