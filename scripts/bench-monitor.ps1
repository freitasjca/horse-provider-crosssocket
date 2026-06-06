# bench-monitor.ps1
# Continuously samples bench server process metrics and writes to CSV, InfluxDB, or both.
#
# Usage:
#   # CSV only (default)
#   powershell -ExecutionPolicy Bypass -File bench-monitor.ps1
#
#   # InfluxDB only
#   powershell -ExecutionPolicy Bypass -File bench-monitor.ps1 `
#       -Mode InfluxDB -InfluxUrl http://192.168.1.10:8086 -InfluxToken my-bench-token -HostTag PC1
#
#   # Both CSV and InfluxDB
#   powershell -ExecutionPolicy Bypass -File bench-monitor.ps1 `
#       -Mode Both -InfluxUrl http://192.168.1.10:8086 -InfluxToken my-bench-token -HostTag PC2
#
# InfluxDB setup: see observability/docker-compose.yml
# Default token/org/bucket must match DOCKER_INFLUXDB_INIT_* values in docker-compose.yml

param(
    [ValidateSet("CSV","InfluxDB","Both")]
    [string]$Mode         = "CSV",

    [int]   $IntervalSec  = 2,

    # CSV output path -- auto-named by default
    [string]$OutFile      = "bench-monitor-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    # InfluxDB 2.x connection
    [string]$InfluxUrl    = "http://localhost:8086",
    [string]$InfluxToken  = "my-bench-token",
    [string]$InfluxOrg    = "bench",
    [string]$InfluxBucket = "horse-bench",

    # Tag applied to every metric -- use PC1, PC2 etc. to distinguish machines
    [string]$HostTag      = $env:COMPUTERNAME
)

# ── Config ────────────────────────────────────────────────────────────────────

$benchProcs = @(
    "HorseBenchIndy",
    "HorseBenchCrossSocket",
    "HorseBenchMormot",
    "HorseBenchRawCrossSocket",
    "HorseBenchRawMormot"
)

$logicalCores = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors

# ── Initialise outputs ────────────────────────────────────────────────────────

if ($Mode -in "CSV","Both") {
    "Timestamp,Host,Process,PID,Threads,Handles,WorkingSetMB,CpuTotalSec,CpuPct" |
        Out-File $OutFile -Encoding ascii
    Write-Host "CSV      -> $OutFile"
}

$influxUri     = $null
$influxHeaders = $null

if ($Mode -in "InfluxDB","Both") {
    $influxUri     = "$InfluxUrl/api/v2/write?org=$InfluxOrg&bucket=$InfluxBucket&precision=s"
    $influxHeaders = @{
        Authorization  = "Token $InfluxToken"
        "Content-Type" = "text/plain; charset=utf-8"
    }
    Write-Host "InfluxDB -> $InfluxUrl  org=$InfluxOrg  bucket=$InfluxBucket  host=$HostTag"

    try {
        Invoke-RestMethod -Uri "$InfluxUrl/ping" -Method GET -TimeoutSec 3 | Out-Null
        Write-Host "[OK] InfluxDB reachable"
    } catch {
        Write-Host "[WARN] InfluxDB not reachable at $InfluxUrl -- will keep retrying each interval"
    }
}

Write-Host "Interval : ${IntervalSec}s  |  Ctrl+C to stop"
Write-Host ""

# ── State for CPU delta calculation ───────────────────────────────────────────

$prevCpuSec  = @{}   # key = PID string
$prevSampleT = Get-Date

# ── Main loop ─────────────────────────────────────────────────────────────────

while ($true) {
    $now      = Get-Date
    $tsStr    = $now.ToString("yyyy-MM-dd HH:mm:ss")
    $unixTs   = [int64]($now.ToUniversalTime() - [datetime]"1970-01-01").TotalSeconds
    $elapsed  = ($now - $prevSampleT).TotalSeconds
    $prevSampleT = $now

    # System-level metrics
    $osInfo       = Get-CimInstance Win32_OperatingSystem
    $freeRamMB    = [math]::Round($osInfo.FreePhysicalMemory / 1KB, 0)
    $twCount      = [int](netstat -ano | Select-String "TIME_WAIT").Count
    $totalThreads = [int](Get-Process |
                        ForEach-Object { $_.Threads.Count } |
                        Measure-Object -Sum).Sum

    $influxLines = [System.Collections.Generic.List[string]]::new()

    # System metrics -- one row per sample
    $influxLines.Add(
        "bench_system,host=$HostTag " +
        "free_ram_mb=$($freeRamMB)i," +
        "time_wait=$($twCount)i," +
        "total_threads=$($totalThreads)i " +
        "$unixTs"
    )

    $procCount = 0

    foreach ($name in $benchProcs) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $procCount++
            $pid      = $p.Id
            $key      = "$pid"
            $cpuTotal = [math]::Round($p.TotalProcessorTime.TotalSeconds, 3)
            $wsMB     = [math]::Round($p.WorkingSet64 / 1MB, 1)
            $threads  = [int]$p.Threads.Count
            $handles  = [int]$p.HandleCount

            # CPU % = delta cpu / elapsed wall time / cores * 100
            $cpuPct = 0.0
            if ($prevCpuSec.ContainsKey($key) -and $elapsed -gt 0) {
                $cpuPct = [math]::Round(
                    ($cpuTotal - $prevCpuSec[$key]) / $elapsed / $logicalCores * 100, 1)
                if ($cpuPct -lt 0) { $cpuPct = 0.0 }
            }
            $prevCpuSec[$key] = $cpuTotal

            # CSV row
            if ($Mode -in "CSV","Both") {
                "{0},{1},{2},{3},{4},{5},{6:F1},{7:F3},{8:F1}" -f
                    $tsStr, $HostTag, $p.Name, $pid,
                    $threads, $handles, $wsMB, $cpuTotal, $cpuPct |
                Out-File $OutFile -Append -Encoding ascii
            }

            # InfluxDB line protocol
            # Integer fields need trailing 'i'; floats have no suffix
            $influxLines.Add(
                "bench_server,host=$HostTag,process=$($p.Name),pid=$pid " +
                "threads=$($threads)i," +
                "handles=$($handles)i," +
                "working_set_mb=$wsMB," +
                "cpu_total_s=$cpuTotal," +
                "cpu_pct=$cpuPct " +
                "$unixTs"
            )
        }
    }

    # Purge stale PIDs from CPU tracking (process restarted or stopped)
    $livePids = [System.Collections.Generic.HashSet[string]]::new()
    Get-Process | ForEach-Object { [void]$livePids.Add("$($_.Id)") }
    $stalePids = @($prevCpuSec.Keys | Where-Object { -not $livePids.Contains($_) })
    foreach ($k in $stalePids) { $prevCpuSec.Remove($k) }

    # InfluxDB batch write
    if ($Mode -in "InfluxDB","Both") {
        $body = $influxLines -join "`n"
        try {
            Invoke-RestMethod -Uri $influxUri -Method POST `
                -Headers $influxHeaders -Body $body -TimeoutSec 5 | Out-Null
        } catch {
            Write-Host "[$tsStr] InfluxDB write error: $($_.Exception.Message)"
        }
    }

    # Console status
    Write-Host ("[$tsStr]  procs={0,2}  TIME_WAIT={1,4}  freeRAM={2,6}MB  threads={3,5}" -f
        $procCount, $twCount, $freeRamMB, $totalThreads)

    Start-Sleep -Seconds $IntervalSec
}
