# bench-resources.ps1
# Snapshot of system resources relevant to the Horse benchmark suite.
# Run while bench-scenario3.bat is active to catch peak Indy thread count
# and TIME_WAIT pressure in real time.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File bench-resources.ps1

# bench-monitor.ps1  —  run in a second PowerShell window while bench runs
#   param(
#       [int]$IntervalSec = 2,
#       [string]$OutFile  = "bench-monitor-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
#   )

# ┌───────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────┐
# │            Section            │                                            Relevance                                             │
# ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────┤
# │ Logical cores                 │ CrossSocket WorkerPool cap (4–64 threads); mORMot IOCP pool size                                 │
# ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────┤
# │ Available RAM                 │ Indy thread stack budget (~1 MB each × c=500 = 500 MB just for stacks)                           │
# ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────┤
# │ Ephemeral port range          │ Max simultaneous outbound connections bombardier can open; default 16384 ports is tight at c=500 │
# ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────┤
# │ TIME_WAIT count               │ Ports stuck cooling down — if high, bombardier can't open new connections                        │
# ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────┤
# │ TCP autotuning                │ Affects throughput on large responses (Scenario 5 / large body)                                  │
# ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────┤
# │ Live thread count per process │ Shows exactly how many threads Indy is holding vs CrossSocket                                    │
# ├───────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────┤
# │ Power plan                    │ "Balanced" parks cores mid-benchmark — must be "High performance"                                │
# └───────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────┘
# Run it while bench-scenario3.bat is active (during the Indy run) to catch the peak thread count and TIME_WAIT pressure in real time.

$sep = "=" * 72

# ── CPU ───────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host $sep
Write-Host " CPU"
Write-Host $sep
$cpu = Get-CimInstance Win32_Processor
Write-Host ("  Model          : {0}" -f $cpu.Name.Trim())
Write-Host ("  Physical cores : {0}" -f $cpu.NumberOfCores)
Write-Host ("  Logical cores  : {0}" -f $cpu.NumberOfLogicalProcessors)
Write-Host ("  Base clock     : {0} MHz" -f $cpu.MaxClockSpeed)

# ── RAM ───────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host $sep
Write-Host " RAM"
Write-Host $sep
$os = Get-CimInstance Win32_OperatingSystem
$totalGB  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$freeGB   = [math]::Round($os.FreePhysicalMemory     / 1MB, 1)
$usedGB   = [math]::Round($totalGB - $freeGB, 1)
Write-Host ("  Total          : {0} GB" -f $totalGB)
Write-Host ("  Used now       : {0} GB" -f $usedGB)
Write-Host ("  Available now  : {0} GB" -f $freeGB)

# Indy thread budget: each thread needs ~1 MB stack
$indyBudget = [math]::Round($os.FreePhysicalMemory / 1KB)
Write-Host ("  Indy thread budget (approx ~1 MB stack each) : ~{0}" -f $indyBudget)

# ── Power plan ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host $sep
Write-Host " Power plan  (should be High performance for benchmarks)"
Write-Host $sep
$scheme = (powercfg /getactivescheme) -join " "
Write-Host ("  {0}" -f $scheme.Trim())
if ($scheme -match "Balanced") {
    Write-Host "  WARNING: Balanced plan parks cores mid-benchmark -- switch to High performance"
}

# ── TCP stack ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host $sep
Write-Host " TCP stack"
Write-Host $sep

$dp = netsh int ipv4 show dynamicportrange tcp
$start = ($dp | Select-String "Start Port"    | ForEach-Object { $_ -replace '.*:\s*', '' }).Trim()
$count = ($dp | Select-String "Number of Ports" | ForEach-Object { $_ -replace '.*:\s*', '' }).Trim()
Write-Host ("  Ephemeral port range   : start={0}  count={1}" -f $start, $count)
Write-Host ("  Max simultaneous conns : ~{0}  (bombardier c=500 needs at least 500)" -f $count)

$tw = (netstat -ano | Select-String "TIME_WAIT").Count
Write-Host ("  TIME_WAIT sockets now  : {0}" -f $tw)
if ($tw -gt 2000) {
    Write-Host "  WARNING: high TIME_WAIT count may cause bombardier dial failures at c=500"
}

Write-Host ""
Write-Host "  TCP global settings:"
netsh int tcp show global |
    Select-String "Auto-Tuning Level|Receive-Side Scaling|RSS|Chimney|ECN" |
    ForEach-Object { Write-Host ("    {0}" -f $_.Line.Trim()) }

# ── ESET / Defender ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host $sep
Write-Host " Security software  (network interception adds latency)"
Write-Host $sep
$secProcs = @("ekrn","egui","MsMpEng","NisSrv","MpCmdRun")
foreach ($name in $secProcs) {
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($p) {
        Write-Host ("  RUNNING  {0,-14} CPU={1,5:F1}s  Mem={2,5} MB" -f
            $p.Name,
            $p.TotalProcessorTime.TotalSeconds,
            [math]::Round($p.WorkingSet64 / 1MB, 0))
    }
}
$found = @($secProcs | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
if ($found.Count -eq 0) {
    Write-Host "  None of the known AV processes detected."
}

# ── Live bench server stats ───────────────────────────────────────────────────
Write-Host ""
Write-Host $sep
Write-Host " Bench server processes  (live snapshot)"
Write-Host $sep

$benchProcs = @(
    "HorseBenchIndy",
    "HorseBenchCrossSocket",
    "HorseBenchMormot",
    "HorseBenchRawCrossSocket",
    "HorseBenchRawMormot"
)

$anyFound = $false
foreach ($name in $benchProcs) {
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        $anyFound = $true
        Write-Host ("  {0,-28}  threads={1,4}  handles={2,5}  workingSet={3,4} MB" -f
            $p.Name,
            $p.Threads.Count,
            $p.HandleCount,
            [math]::Round($p.WorkingSet64 / 1MB, 0))
    }
}
if (-not $anyFound) {
    Write-Host "  No bench server processes are currently running."
}

# ── Total system thread count ─────────────────────────────────────────────────
Write-Host ""
Write-Host $sep
Write-Host " System-wide thread summary"
Write-Host $sep
$allThreads = (Get-Process | ForEach-Object { $_.Threads.Count } | Measure-Object -Sum).Sum
Write-Host ("  Total threads (all processes) : {0}" -f $allThreads)

# ── Timestamp ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host $sep
Write-Host ("  Snapshot taken : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Write-Host $sep
Write-Host ""
