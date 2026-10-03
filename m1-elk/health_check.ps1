Write-Host "=== TraceHunt ELK Stack Comprehensive Health Check ===" -ForegroundColor Cyan

# 1. Elasticsearch Check
try {
    $es = Invoke-RestMethod -Uri "http://localhost:9200/_cluster/health" -Method Get
    Write-Host "[OK] Elasticsearch Status: $($es.status) | Nodes: $($es.number_of_nodes)" -ForegroundColor Green
} catch {
    Write-Host "[FAIL] Elasticsearch unreachable on port 9200!" -ForegroundColor Red
}

# 2. Kibana Check
try {
    $kibana = Invoke-WebRequest -Uri "http://localhost:5601/status" -Method Get -UseBasicParsing
    if ($kibana.StatusCode -eq 200) {
        Write-Host "[OK] Kibana running on port 5601" -ForegroundColor Green
    }
} catch {
    Write-Host "[FAIL] Kibana unreachable on port 5601!" -ForegroundColor Red
}

# 3. Logstash Port Check
$logstashPort = 5000
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("localhost", $logstashPort)
    if ($tcp.Connected) {
        Write-Host "[OK] Logstash TCP listening on port $logstashPort" -ForegroundColor Green
        
        # Send Test Event
        $writer = New-Object System.IO.StreamWriter($tcp.GetStream())
        $testEvent = '{"event_type": "health_check", "message": "Test event from health check script", "severity": "info"}'
        $writer.WriteLine($testEvent)
        $writer.Flush()
        $tcp.Close()
        Write-Host "[OK] Test event dispatched to Logstash successfully!" -ForegroundColor Green
    }
} catch {
    Write-Host "[FAIL] Could not connect to Logstash on port $logstashPort!" -ForegroundColor Red
}

# 4. Verify End-to-End Event Ingestion in Elasticsearch
Start-Sleep -Seconds 3
try {
    $search = Invoke-RestMethod -Uri "http://localhost:9200/_search?q=event_type:health_check" -Method Get
    $total = $search.hits.total.value
    if ($total -gt 0) {
        Write-Host "[OK] End-to-End Test Passed: Found $total test event(s) in Elasticsearch!" -ForegroundColor Green
    } else {
        Write-Host "[WARN] No test events found in Elasticsearch yet." -ForegroundColor Yellow
    }
} catch {
    Write-Host "[FAIL] Failed to query Elasticsearch for test event." -ForegroundColor Red
}
