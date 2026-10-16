# ---------- Config ----------
$server    = "put_server_address_here"
$database  = "database_name"
$sharePath = "share_path_here"
$outDir    = $PSScriptRoot
$logFile   = Join-Path $PSScriptRoot "Extract.log"

# Credential Taregsts
$DB = 'DB_credential_Target'
$SMB_Server = 'SMB_Server_Address'

$jobs = @(
    @{ Name = "file_name";   Query     = "EXEC dbo.tccsa_OneRoster_users_NoGB @DistCd = 'ASHC', @AppCd = NULL, @SchlYr = NULL"   }
)

# ---------- Logging ----------
Set-Content -Path $logFile -Value $null   # overwrite previous run's log

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

$runTimer = [System.Diagnostics.Stopwatch]::StartNew()
Write-Log "=== Run started ==="
Write-Log "User: $(whoami) | Host: $env:COMPUTERNAME | PowerShell: $($PSVersionTable.PSVersion)"
Write-Log "Server: $server | Database: $database | Share: $sharePath | Jobs: $($jobs.Count)"

# ---------- Setup ----------
$sqlCred = Get-StoredCredential -Target $DB
if (-not $sqlCred) {
    Write-Log "SQL credential 'SQL_myserver' not found for this account" "ERROR"
    exit 1
}
Write-Log "SQL credential loaded (user: $($sqlCred.UserName))"

$shareCred = Get-StoredCredential -Target $SMB_Server
if (-not $shareCred) { Write-Log "Share credential 'FILESERVER_share' not found" "ERROR"; exit 1 }

#try {
#    New-PSDrive -Name Z -PSProvider FileSystem -Root $sharePath -Persist -Force -Credential $shareCred -ErrorAction Stop | Out-Null
#    Write-Log "Mapped Z: to $sharePath (user: $($shareCred.UserName))"
#    $sharePath = "Z:\"
#}
#catch {
#    Write-Log "Could not map $sharePath : $($_.Exception.Message)" "ERROR"
#    exit 1
#}

$failed = @()

# ---------- Run each job ----------
foreach ($job in $jobs) {
    $jobTimer  = [System.Diagnostics.Stopwatch]::StartNew()
    $localFile = Join-Path $outDir "$($job.Name).csv"
    Write-Log "[$($job.Name)] Starting"

    try {
        $params = @{
            ServerInstance         = $server
            Database               = $database
            Credential             = $sqlCred
            QueryTimeout           = 600
            TrustServerCertificate = $true
            ErrorAction            = "Stop"
        }
        if ($job.Query)     { $params.Query     = $job.Query;     Write-Log "[$($job.Name)] Query: $($job.Query)" }
        if ($job.InputFile) { $params.InputFile = $job.InputFile; Write-Log "[$($job.Name)] SQL file: $($job.InputFile)" }
        if ($job.Variables) { $params.Variable  = $job.Variables }

        $result = Invoke-Sqlcmd @params
        $rows   = @($result)

        if ($rows.Count -eq 0 -or $null -eq $result) {
            Write-Log "[$($job.Name)] No rows returned, no file written" "WARN"
            continue
        }
        Write-Log "[$($job.Name)] Query returned $($rows.Count) rows in $([math]::Round($jobTimer.Elapsed.TotalSeconds,1))s"

        # Build CSV lines exactly as SQL returned them
        $cols  = $rows[0].Table.Columns | ForEach-Object ColumnName
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add($cols -join ',')
        foreach ($r in $rows) {
            $vals = foreach ($c in $cols) {
                $v = $r[$c]
                if ($v -is [DBNull]) { '' } else { $v }
            }
            $lines.Add($vals -join ',')
        }
        Set-Content -Path $localFile -Value $lines -Encoding UTF8 -ErrorAction Stop
        $size = (Get-Item $localFile).Length
        Write-Log "[$($job.Name)] Wrote $localFile ($($lines.Count - 1) data rows, $size bytes)"

        Copy-Item -Path $localFile -Destination $sharePath -Force -ErrorAction Stop
        $dest = Join-Path $sharePath "$($job.Name).csv"
        if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq $size)) {
            Write-Log "[$($job.Name)] Copied to $dest (size verified)"
        } else {
            throw "Copy verification failed for $dest"
        }

        # Remove-Item $localFile
        Write-Log "[$($job.Name)] Done in $([math]::Round($jobTimer.Elapsed.TotalSeconds,1))s"
    }
    catch {
        Write-Log "[$($job.Name)] FAILED: $($_.Exception.Message)" "ERROR"
        Write-Log "[$($job.Name)] At: $($_.InvocationInfo.PositionMessage -replace '\s+',' ')" "ERROR"
        $failed += $job.Name
    }

}

# ---------- Result ----------
$runTimer.Stop()
$ok = $jobs.Count - $failed.Count
Write-Log "=== Run finished in $([math]::Round($runTimer.Elapsed.TotalSeconds,1))s | Succeeded/skipped: $ok | Failed: $($failed.Count) ==="

if ($failed.Count -gt 0) {
    Write-Log "Failed jobs: $($failed -join ', ')" "ERROR"
    exit 1
}
exit 0