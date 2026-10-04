# TraceHunt ELK Health Check Script
# Enforces strict non-zero exit code on failure, zero on complete success.
$ErrorActionPreference = "Stop"

# Configuration
$EsUrl =$env:ES_URL
if (-not $EsUrl) {$EsUrl = "http://127.0.0.1:9200" }

$LogstashHost =$env:LOGSTASH_HOST
if (-not $LogstashHost) {$LogstashHost = "127.0.0.1" }

$LogstashPort =$env:LOGSTASH_PORT
if (-not $LogstashPort) {$LogstashPort = 5000 }

$ElasticPassword =$env:ELASTIC_PASSWORD
if (-not $ElasticPassword) {
    Write-Error "ELASTIC_PASSWORD environment variable is required."
    exit 1
}

# Setup Basic Authentication Header
$AuthPair = "elastic:${ElasticPassword}"
$EncodedAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($AuthPair))
$AuthHeader = @{ Authorization = "Basic $EncodedAuth" }

Write-Host "--- 1. Authenticated Elasticsearch Cluster Health Check ---"
try {
    $clusterHealth = Invoke-RestMethod -Uri "$EsUrl/_cluster/health" -Headers $AuthHeader -Method Get -TimeoutSec 5
    $status =$clusterHealth.status
    if ($status -eq "green" -or $status -eq "yellow") {
        Write-Host "[OK] Elasticsearch cluster health is '$status'."
    } else {
        Write-Error "[FAIL] Elasticsearch cluster status is '$status'."
        exit 1
    }
} catch {
    Write-Error "[FAIL] Failed to reach Elasticsearch cluster health endpoint: $_"
    exit 1
}

Write-Host "`n--- 2. Logstash TCP Ingestion & Index Pipeline Verification ---"
$runId = [Guid]::NewGuid().ToString()
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
$todayIndex = "tracehunt-raw-" + (Get-Date).ToUniversalTime().ToString("yyyy.MM.dd")

# Construct event object and serialize cleanly via ConvertTo-Json
$eventObject = [PSCustomObject]@{
    "@timestamp" = $timestamp
    "run_id"     = $runId
    "event"      = [PSCustomObject]@{
        "category" = "healthcheck"
        "type"     = "synthetic"
    }
    "host"       = [PSCustomObject]@{
        "name" = $env:COMPUTERNAME
    }
}
$jsonPayload = $eventObject | ConvertTo-Json -Compress

# Ingest event over TCP socket with separate StreamWriter lines
try {
    Write-Host "Connecting to Logstash at ${LogstashHost}:${LogstashPort}..."
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect($LogstashHost, [int]$LogstashPort)
    
    $stream = $tcp.GetStream()
    
    # StreamWriter creation on its own line
    $writer = New-Object System.IO.StreamWriter($stream)
    
    # Writing event on separate line
    $writer.WriteLine($jsonPayload)
    
    # Flush and Close separated cleanly
    $writer.Flush()
    $tcp.Close()
    
    Write-Host "[OK] Synthetic event sent with run_id: $runId"
} catch {
    Write-Error "[FAIL] Could not send event to Logstash: $_"
    exit 1
}

Write-Host "`n--- 3. Bounded Polling for Ingested Event in Elasticsearch ---"
# Query payload targeting the unique run_id
$queryObject = [PSCustomObject]@{
    query = [PSCustomObject]@{
        term = [PSCustomObject]@{
            "run_id" = $runId
        }
    }
}
$queryJson =$queryObject | ConvertTo-Json -Compress

$maxAttempts = 10$pollIntervalSec = 1
$found =$false

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Start-Sleep -Seconds $pollIntervalSec
    try {
        $searchResponse = Invoke-RestMethod -Uri "$EsUrl/$todayIndex/_search" `
            -Headers $AuthHeader `
            -Method Post `
            -Body $queryJson `
            -ContentType "application/json" `
            -TimeoutSec 5

        if ($searchResponse.hits.total.value -gt 0) {
            $found = $true
            Write-Host "[OK] Event indexed successfully after ${attempt} attempt(s) in $todayIndex."
            break
        }
    } catch {
        # Logstash might still be processing; retry until maxAttempts
    }
    Write-Host "Polling attempt $attempt/$maxAttempts for run_id ($runId)..."
}

if (-not $found) {
    Write-Error "[FAIL] Event with run_id '$runId' was not found in '$todayIndex' within $($maxAttempts * $pollIntervalSec) seconds."
    exit 1
}

Write-Host "`n[SUCCESS] All ELK health checks passed!"
exit 0
