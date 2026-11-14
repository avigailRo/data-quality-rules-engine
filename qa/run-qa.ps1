<#
  End-to-end QA for the data-controls project. Writes everything to qa\qa-log.txt and a summary to qa\qa-summary.txt.

  Usage (from the project folder):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\qa\run-qa.ps1
  Options:
    -ResetDb        recreate the DataControls database even if it already exists (drops it!)
    -Server ".\SQLEXPRESS"
    -SkipFrontend   skip npm install / ng build
    -StopServices   stop API / Python / Angular processes at the end (default: leave them running for UI testing)
#>
param(
    [string]$Server = ".\SQLEXPRESS",
    [switch]$ResetDb,
    [switch]$SkipFrontend,
    [switch]$StopServices
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$qa = $PSScriptRoot
$log = Join-Path $qa 'qa-log.txt'
$summaryFile = Join-Path $qa 'qa-summary.txt'
$base = 'http://localhost:5080'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Set-Content -Path $log -Value "QA run $(Get-Date -Format s)" -Encoding UTF8
$script:pass = 0; $script:fail = 0; $script:results = New-Object System.Collections.ArrayList

function Log([string]$msg) { Add-Content -Path $log -Value $msg -Encoding UTF8; Write-Host $msg }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; $tag = 'PASS' } else { $script:fail++; $tag = 'FAIL' }
    $line = "[$tag] $name" + $(if ($detail) { " :: $detail" } else { '' })
    [void]$script:results.Add($line); Log $line
}
function Section([string]$name) { Log ""; Log "==================== $name ===================="; }
function Run-Cmd([string]$title, [string]$exe, [string[]]$cmdArgs, [string]$cwd = $root) {
    Log "--- $title :: $exe $($cmdArgs -join ' ')"
    Push-Location $cwd
    $lines = New-Object System.Collections.ArrayList
    try {
        # stream every line to the log as it arrives, so a hang is visible
        & $exe @cmdArgs 2>&1 | ForEach-Object { $l = "$_"; [void]$lines.Add($l); Add-Content -Path $log -Value $l -Encoding UTF8 }
        $code = $LASTEXITCODE
    } catch { [void]$lines.Add($_.Exception.Message); $code = -1 }
    Pop-Location
    $out = $lines -join "`n"
    Log "--- exit code: $code"
    return @{ Code = $code; Out = $out }
}

# ---------------- SQL helpers (System.Data.SqlClient, no sqlcmd needed) ----------------
function New-Conn([string]$db = 'master') {
    # Pooling=False: the permission tests impersonate dc_rule_reader (EXECUTE AS) and fail on purpose; a pooled
    # connection would come back to the next query in that broken state (this caused the "OR oracle = 0" failure).
    $c = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=$db;Integrated Security=True;TrustServerCertificate=True;Pooling=False")
    $c.Open(); return $c
}
function Sql-Query([string]$sql, [string]$db = 'DataControls') {
    $c = New-Conn $db
    try {
        $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 60
        $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader()); return ,$t
    } finally { $c.Close() }
}
function Sql-Scalar([string]$sql, [string]$db = 'DataControls') {
    $c = New-Conn $db
    try { $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; return $cmd.ExecuteScalar() } finally { $c.Close() }
}
function Sql-Ids([string]$sql) {
    # read with a plain DataReader (DataTable.Load returned an empty set once in QA - not reproducible, so avoid it here)
    $c = New-Conn 'DataControls'
    try {
        $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 60
        $rd = $cmd.ExecuteReader(); $ids = New-Object System.Collections.ArrayList
        while ($rd.Read()) { [void]$ids.Add([string]$rd.GetValue(0)) }
        $rd.Close()
        return @($ids | Sort-Object { [int]$_ })
    } finally { $c.Close() }
}
function Run-SqlFile([string]$path) {
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $batches = [regex]::Split($text, '(?im)^\s*GO\s*$') | Where-Object { $_.Trim().Length -gt 0 }
    $c = New-Conn 'master'
    try {
        foreach ($b in $batches) { $cmd = $c.CreateCommand(); $cmd.CommandText = $b; $cmd.CommandTimeout = 300; [void]$cmd.ExecuteNonQuery() }
    } finally { $c.Close() }
}

# ---------------- HTTP helper ----------------
function Call-Api([string]$method, [string]$path, [string]$body = $null, [string]$user = 'author', [hashtable]$extra = @{}) {
    $headers = @{}
    if ($user) { $headers['X-Demo-User'] = $user }
    foreach ($k in $extra.Keys) { $headers[$k] = $extra[$k] }
    $p = @{ Uri = "$base$path"; Method = $method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 120 }
    if ($body) { $p['Body'] = [Text.Encoding]::UTF8.GetBytes($body); $p['ContentType'] = 'application/json; charset=utf-8' }
    try {
        $r = Invoke-WebRequest @p
        $content = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        $json = $null
        if ($content) {
            try {
                # Windows PowerShell 5.1 returns a JSON array as ONE object - unroll it
                if ($content.TrimStart().StartsWith('[')) { $json = @($content | ConvertFrom-Json | ForEach-Object { $_ }) }
                else { $json = $content | ConvertFrom-Json }
            } catch {}
        }
        return @{ Status = [int]$r.StatusCode; Json = $json; Raw = $content; Headers = $r.Headers }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8); $content = $sr.ReadToEnd()
            $json = $null; try { $json = $content | ConvertFrom-Json } catch {}
            return @{ Status = [int]$resp.StatusCode; Json = $json; Raw = $content }
        }
        return @{ Status = 0; Raw = $_.Exception.Message }
    }
}
function Wait-Url([string]$url, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3; if ($r.StatusCode -eq 200) { return $true } } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}
function Run-Rule([string]$ruleId, [string]$user = 'author') {
    $start = Call-Api POST "/api/v1/rules/$ruleId/runs" $null $user
    if ($start.Status -ne 202) { return @{ Error = "start returned $($start.Status) $($start.Raw)" } }
    $runId = $start.Json.id
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Milliseconds 700
        $run = (Call-Api GET "/api/v1/runs/$runId").Json
        if ($run.status -in @('Succeeded', 'Failed', 'TimedOut')) { break }
    }
    if ($run.status -ne 'Succeeded') { return @{ Error = "run status $($run.status): $($run.errorCode) $($run.errorMessage)"; Run = $run } }
    $page = (Call-Api GET "/api/v1/runs/$runId/violations?pageSize=100").Json
    $keys = @($page.items | ForEach-Object { [string]$_.recordKey } | Sort-Object { [int]$_ })
    return @{ Run = $run; Page = $page; Keys = $keys; RunId = $runId }
}
function Same([string[]]$a, [string[]]$b) { return (($a -join ',') -eq ($b -join ',')) }

$procs = @{}

# =====================================================================
Section 'ENVIRONMENT'
foreach ($t in @(@('dotnet', '--version'), @('node', '-v'), @('npm', '-v'), @('python', '--version'), @('git', '--version'))) {
    $r = Run-Cmd "version" $t[0] @($t[1])
    Check "tool available: $($t[0])" ($r.Code -eq 0) ($r.Out.Trim() -split "`n" | Select-Object -First 1)
}
foreach ($u in @('https://api.nuget.org/v3/index.json', 'https://registry.npmjs.org/', 'https://pypi.org/simple/pip/')) {
    try { $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 15; Check "network: $u" ($r.StatusCode -eq 200) }
    catch { Check "network: $u" $false $_.Exception.Message }
}
try { $drv = (Get-OdbcDriver -Platform 64-bit | Where-Object Name -like 'ODBC Driver*SQL Server*' | Select-Object -ExpandProperty Name) -join '; '; Check 'ODBC driver for SQL Server (Python)' ([bool]$drv) $drv } catch { Log "Get-OdbcDriver failed: $_" }

# =====================================================================
Section 'DATABASE'
try {
    $exists = Sql-Scalar "SELECT DB_ID(N'DataControls')" 'master'
    Check "connect to SQL Server $Server" $true
    if ($exists -is [DBNull] -or $null -eq $exists -or $ResetDb) {
        Log $(if ($ResetDb) { 'ResetDb requested - recreating DataControls' } else { 'DataControls does not exist - creating' })
        foreach ($f in Get-ChildItem (Join-Path $root 'db') -Filter '0*.sql' | Sort-Object Name) {
            try { Run-SqlFile $f.FullName; Check "script $($f.Name)" $true } catch { Check "script $($f.Name)" $false ("" + $_.Exception.InnerException.Message + " " + $_.Exception.Message) }
        }
    } else {
        Log 'DataControls already exists - NOT recreated (run with -ResetDb to recreate). Verifying existing database.'
    }

    $tables = Sql-Scalar "SELECT COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name IN ('biz','dq')"
    Check 'tables in biz+dq = 14 (5 biz + 9 dq)' ($tables -eq 14) "found $tables"
    $fks = Sql-Scalar "SELECT COUNT(*) FROM sys.foreign_keys"
    Check 'foreign keys exist' ($fks -ge 10) "found $fks"
    Check '200 employees' ((Sql-Scalar 'SELECT COUNT(*) FROM biz.Employees') -eq 200)
    Check 'metadata: 5 entities' ((Sql-Scalar 'SELECT COUNT(*) FROM dq.Entity') -eq 5)
    Check 'metadata: 27 fields' ((Sql-Scalar 'SELECT COUNT(*) FROM dq.Field') -eq 27) "found $(Sql-Scalar 'SELECT COUNT(*) FROM dq.Field')"
    Check 'metadata: 9 relationships' ((Sql-Scalar 'SELECT COUNT(*) FROM dq.Relationship') -eq 9)
    Check '7 sample rules' ((Sql-Scalar "SELECT COUNT(*) FROM dq.[Rule] WHERE CreatedBy = N'seed'") -eq 7)
    $heb = Sql-Scalar "SELECT DisplayName FROM dq.Entity WHERE [Key]=N'employee'"
    Check 'Hebrew text stored correctly' ($heb -eq 'עובד') "value: $heb"

    # Least privilege: the rule reader must not write or read dq
    function Try-As([string]$sql) { try { [void](Sql-Scalar "EXECUTE AS USER = N'dc_rule_reader'; $sql; REVERT;"); return 'ok' } catch { return ('' + $_.Exception.InnerException.Message + ' ' + $_.Exception.Message) } }
    $r1 = Try-As 'SELECT COUNT(*) FROM biz.Employees'
    Check 'dc_rule_reader CAN read biz' ($r1 -eq 'ok') $r1
    $r2 = Try-As "UPDATE biz.Employees SET Salary = Salary WHERE Id = 1"
    Check 'dc_rule_reader CANNOT update biz' ($r2 -ne 'ok') ($r2.Substring(0, [Math]::Min(150, $r2.Length)))
    $r3 = Try-As 'SELECT COUNT(*) FROM dq.[Rule]'
    Check 'dc_rule_reader CANNOT read dq' ($r3 -ne 'ok') ($r3.Substring(0, [Math]::Min(150, $r3.Length)))
    $r4 = Try-As 'CREATE TABLE biz.Hack (Id INT)'
    Check 'dc_rule_reader CANNOT create tables' ($r4 -ne 'ok') ($r4.Substring(0, [Math]::Min(150, $r4.Length)))
} catch {
    Check 'database section' $false ($_.Exception.Message)
}

# =====================================================================
Section 'BACKEND BUILD AND UNIT TESTS'
$backend = Join-Path $root 'backend'
# a previous QA run leaves the API/AI running; a running API locks its DLLs and breaks the build
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'uvicorn' -and $_.CommandLine -match 'app\.main:app' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
foreach ($port in 5080, 8000, 4200) {
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
}
Start-Sleep -Seconds 2
# If an old process that this window cannot stop (e.g. started from an elevated window) still holds a port,
# use a free port instead - never test against a stale process by accident.
function Get-FreePort([int]$preferred, [int]$from) {
    if (@(Get-NetTCPConnection -LocalPort $preferred -State Listen -ErrorAction SilentlyContinue).Count -eq 0) { return $preferred }
    foreach ($p in $from..($from + 30)) { if (@(Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue).Count -eq 0) { return $p } }
    return $preferred
}
$apiPort = Get-FreePort 5080 5090; $aiPort = Get-FreePort 8000 8010; $webPort = Get-FreePort 4200 4210
if ($apiPort -ne 5080 -or $aiPort -ne 8000 -or $webPort -ne 4200) { Log "NOTE: ports in use by processes this window cannot stop - using API=$apiPort AI=$aiPort UI=$webPort" }
$base = "http://localhost:$apiPort"
$r = Run-Cmd 'dotnet restore' 'dotnet' @('restore', 'DataControls.slnx', '-v', 'normal') $backend
Check 'dotnet restore' ($r.Code -eq 0)
$r = Run-Cmd 'dotnet build' 'dotnet' @('build', 'DataControls.slnx', '--no-restore', '-c', 'Debug', '-nologo', '-clp:ErrorsOnly;Summary') $backend
Check 'dotnet build' ($r.Code -eq 0)
$buildOk = ($r.Code -eq 0)
if ($buildOk) {
    $r = Run-Cmd 'dotnet test' 'dotnet' @('test', 'DataControls.slnx', '--no-build', '-nologo', '-v', 'minimal') $backend
    $m = [regex]::Match($r.Out, 'Failed:\s*(\d+),\s*Passed:\s*(\d+)')
    Check 'dotnet test' ($r.Code -eq 0) $(if ($m.Success) { "failed=$($m.Groups[1].Value) passed=$($m.Groups[2].Value)" } else { 'see log' })
}

# =====================================================================
Section 'API INTEGRATION'
if ($buildOk) {
    $apiProj = Join-Path $backend 'src\DataControls.Api'
    $procs.api = Start-Process -FilePath 'dotnet' -ArgumentList @('run', '--no-build', '--project', "`"$apiProj`"", '--', '--urls', $base, "--Advisor:BaseUrl=http://127.0.0.1:$aiPort") -WorkingDirectory $apiProj `
        -RedirectStandardOutput (Join-Path $qa 'api.out.log') -RedirectStandardError (Join-Path $qa 'api.err.log') -PassThru -WindowStyle Hidden
    $up = Wait-Url "$base/health/ready" 60
    Check 'API starts and /health/ready = 200' $up
    if (-not $up) { Log (Get-Content (Join-Path $qa 'api.out.log') -Raw -ErrorAction SilentlyContinue); Log (Get-Content (Join-Path $qa 'api.err.log') -Raw -ErrorAction SilentlyContinue) }
}
if ($up) {
    # --- auth ---
    Check 'no user header -> 401' ((Call-Api GET '/api/v1/rules' $null '').Status -eq 401)
    Check 'viewer can list rules' ((Call-Api GET '/api/v1/rules' $null 'viewer').Status -eq 200)
    $cat = Call-Api GET '/api/v1/catalog/entities'
    Check 'catalog returns 5 entities' ($cat.Status -eq 200 -and @($cat.Json).Count -eq 5)
    # case-sensitive: the business key "employees" (a relationship) is allowed, the physical table name "Employees" is not
    Check 'catalog exposes no physical names' (-not ($cat.Raw -cmatch '"Employees"|"ProjectAssignments"|"schema(Name)?"|"tableName"|"columnName"|"biz"'))
    $verify = Call-Api POST '/api/v1/admin/catalog/verify' '{}' 'admin'
    Check 'catalog verify (admin) is valid' ($verify.Status -eq 200 -and $verify.Json.valid -eq $true) $verify.Raw
    Check 'catalog verify forbidden for author' ((Call-Api POST '/api/v1/admin/catalog/verify' '{}' 'author').Status -eq 403)

    # --- sample rules vs. expected planted errors ---
    $expected = [ordered]@{
        '11111111-0000-0000-0000-000000000001' = @('21', '42')
        '11111111-0000-0000-0000-000000000002' = @('30', '45')
        '11111111-0000-0000-0000-000000000003' = @('7', '19', '33')
        '11111111-0000-0000-0000-000000000004' = @('12', '56', '77', '99')
        '11111111-0000-0000-0000-000000000005' = @('15', '25', '150')
        '11111111-0000-0000-0000-000000000006' = @('170', '171')
        '11111111-0000-0000-0000-000000000007' = @('50', '51')
    }
    foreach ($id in $expected.Keys) {
        $res = Run-Rule $id
        if ($res.Error) { Check "sample rule $id" $false $res.Error; continue }
        $okKeys = Same $res.Keys $expected[$id]
        $explained = @($res.Page.items | Where-Object { @($_.reasons).Count -eq 0 }).Count -eq 0
        Check "sample rule $($res.Run.ruleName)" ($okKeys -and $explained) "got [$($res.Keys -join ',')] expected [$($expected[$id] -join ',')]; first reason: $(@($res.Page.items)[0].reasons[0].textHe)"
    }

    # --- dynamic rules vs. an independent hand-written SQL oracle ---
    function Rule-Body([string]$name, [string]$condition, [string]$status = 'Active') {
        return "{""name"":""$name"",""description"":""QA"",""status"":""$status"",""severity"":""Medium"",""definition"":{""schemaVersion"":1,""rootEntity"":""employee"",""condition"":$condition,""output"":{""displayFields"":[""fullName"",""salary""]}}}"
    }
    $condOr = '{"type":"group","id":"g1","logic":"or","negate":false,"children":[{"type":"comparison","id":"c1","left":{"kind":"field","path":["salary"]},"operator":"gt","right":{"kind":"value","value":20000}},{"type":"comparison","id":"c2","left":{"kind":"field","path":["email"]},"operator":"isEmpty"}]}'
    $created = Call-Api POST '/api/v1/rules' (Rule-Body 'QA OR rule' $condOr)
    Check 'create rule via API (201)' ($created.Status -eq 201) $created.Raw.Substring(0, [Math]::Min(200, $created.Raw.Length))
    if ($created.Status -eq 201) {
        $rid = $created.Json.id
        $oracle = Sql-Ids "SELECT Id FROM biz.Employees WHERE Salary > 20000 OR Email IS NULL OR LTRIM(RTRIM(Email)) = N''"
        $res = Run-Rule $rid
        Check 'OR rule matches SQL oracle' (Same $res.Keys $oracle) "api=$($res.Keys.Count) oracle=$($oracle.Count)"

        $condAnd = '{"type":"group","id":"g1","logic":"and","negate":false,"children":[{"type":"comparison","id":"c0","left":{"kind":"field","path":["status"]},"operator":"eq","right":{"kind":"value","value":"A"}},{"type":"group","id":"g2","logic":"or","negate":false,"children":[{"type":"comparison","id":"c1","left":{"kind":"field","path":["salary"]},"operator":"gt","right":{"kind":"value","value":20000}},{"type":"comparison","id":"c2","left":{"kind":"field","path":["email"]},"operator":"isEmpty"}]}]}'
        $upd = Call-Api PUT "/api/v1/rules/$rid" (Rule-Body 'QA AND(OR) rule' $condAnd) 'author' @{ 'If-Match' = '"1"' }
        Check 'update rule with If-Match (version 2)' ($upd.Status -eq 200 -and $upd.Json.version -eq 2) $upd.Raw.Substring(0, [Math]::Min(200, $upd.Raw.Length))
        $stale = Call-Api PUT "/api/v1/rules/$rid" (Rule-Body 'stale' $condAnd) 'author' @{ 'If-Match' = '"1"' }
        Check 'stale update -> 412' ($stale.Status -eq 412)
        $oracle2 = Sql-Ids "SELECT Id FROM biz.Employees WHERE Status = N'A' AND (Salary > 20000 OR Email IS NULL OR LTRIM(RTRIM(Email)) = N'')"
        $res2 = Run-Rule $rid
        Check 'nested AND(OR) rule matches SQL oracle after edit' (Same $res2.Keys $oracle2) "api=$($res2.Keys.Count) oracle=$($oracle2.Count)"
        Check 'rerun is linked to rule version 2' ($res2.Run.ruleVersionNo -eq 2)
    }

    # NULL / three-valued logic: NOT(termination < hire) must include rows with NULL termination
    $condNot = '{"type":"group","id":"g1","logic":"and","negate":true,"children":[{"type":"comparison","id":"c1","left":{"kind":"field","path":["terminationDate"]},"operator":"lt","right":{"kind":"field","path":["hireDate"]}}]}'
    $pv = Call-Api POST '/api/v1/rules/preview' "{""definition"":{""schemaVersion"":1,""rootEntity"":""employee"",""condition"":$condNot}}"
    Check 'NULL semantics: NOT(term < hire) = 198 rows (NULLs not lost)' ($pv.Status -eq 200 -and $pv.Json.totalCount -eq 198) "got $($pv.Json.totalCount)"

    # quantifier ALL (vacuous truth for employees without assignments)
    $condAll = '{"type":"collection","id":"q1","relation":"projectAssignments","quantifier":"all","condition":{"type":"comparison","id":"c1","left":{"kind":"field","path":["endDate"]},"operator":"isNotEmpty"}}'
    $pv = Call-Api POST '/api/v1/rules/preview' "{""definition"":{""schemaVersion"":1,""rootEntity"":""employee"",""condition"":$condAll}}"
    $oracleAll = Sql-Scalar "SELECT COUNT(*) FROM biz.Employees e WHERE NOT EXISTS (SELECT 1 FROM biz.ProjectAssignments pa WHERE pa.EmployeeId = e.Id AND pa.EndDate IS NULL)"
    Check 'quantifier ALL matches oracle' ($pv.Status -eq 200 -and $pv.Json.totalCount -eq $oracleAll) "api=$($pv.Json.totalCount) oracle=$oracleAll"

    # cross-entity many-to-one + LIKE escaping
    $condLike = '{"type":"comparison","id":"c1","left":{"kind":"field","path":["department","name"]},"operator":"contains","right":{"kind":"value","value":"סגורה"}}'
    $pv = Call-Api POST '/api/v1/rules/preview' "{""definition"":{""schemaVersion"":1,""rootEntity"":""employee"",""condition"":$condLike}}"
    $oracleLike = Sql-Scalar "SELECT COUNT(*) FROM biz.Employees e JOIN biz.Departments d ON d.Id = e.DepartmentId WHERE d.Name LIKE N'%סגורה%'"
    Check 'many-to-one + contains matches oracle' ($pv.Status -eq 200 -and $pv.Json.totalCount -eq $oracleLike) "api=$($pv.Json.totalCount) oracle=$oracleLike"
    $condPct = '{"type":"comparison","id":"c1","left":{"kind":"field","path":["email"]},"operator":"contains","right":{"kind":"value","value":"%"}}'
    $pv = Call-Api POST '/api/v1/rules/preview' "{""definition"":{""schemaVersion"":1,""rootEntity"":""employee"",""condition"":$condPct}}"
    Check 'LIKE wildcard is escaped (contains "%" -> 0 rows)' ($pv.Status -eq 200 -and $pv.Json.totalCount -eq 0) "got $($pv.Json.totalCount)"

    # --- security / malicious definitions ---
    $before = Sql-Scalar 'SELECT COUNT(*) FROM biz.Employees'
    $mal = @(
        @('identifier injection', '{"type":"comparison","id":"c1","left":{"kind":"field","path":["salary]; DROP TABLE biz.Employees;--"]},"operator":"isEmpty"}'),
        @('unknown operator', '{"type":"comparison","id":"c1","left":{"kind":"field","path":["salary"]},"operator":"; DELETE FROM biz.Employees","right":{"kind":"value","value":1}}'),
        @('type mismatch', '{"type":"comparison","id":"c1","left":{"kind":"field","path":["salary"]},"operator":"gt","right":{"kind":"value","value":"x OR 1=1"}}'),
        @('collection in path', '{"type":"comparison","id":"c1","left":{"kind":"field","path":["projectAssignments","startDate"]},"operator":"isEmpty"}')
    )
    foreach ($m in $mal) {
        $v = Call-Api POST '/api/v1/rules/validate' "{""definition"":{""schemaVersion"":1,""rootEntity"":""employee"",""condition"":$($m[1])}}" 'viewer'
        $rejected = ($v.Status -eq 400) -or ($v.Status -eq 200 -and $v.Json.valid -eq $false)
        Check "malicious definition rejected: $($m[0])" $rejected "status=$($v.Status) $($v.Raw.Substring(0, [Math]::Min(160, $v.Raw.Length)))"
    }
    $v = Call-Api POST '/api/v1/rules/validate' '{"definition":{"schemaVersion":1,"rootEntity":"employee","sql":"DROP TABLE x","condition":{"type":"comparison","id":"c1","left":{"kind":"field","path":["email"]},"operator":"isEmpty"}}}' 'viewer'
    Check 'extra "sql" property rejected' ($v.Status -eq 200 -and $v.Json.valid -eq $false) $v.Raw.Substring(0, [Math]::Min(160, $v.Raw.Length))
    $pv = Call-Api POST '/api/v1/rules/preview' '{"definition":{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"comparison","id":"x]; DROP TABLE biz.Employees;--","left":{"kind":"field","path":["lastName"]},"operator":"eq","right":{"kind":"value","value":"''; DELETE FROM biz.Employees;--"}}}}'
    Check 'value injection is a parameter (0 rows, no error)' ($pv.Status -eq 200 -and $pv.Json.totalCount -eq 0) "status=$($pv.Status)"
    $deep = '{"type":"comparison","id":"leaf","left":{"kind":"field","path":["salary"]},"operator":"isEmpty"}'
    for ($i = 0; $i -lt 12; $i++) { $deep = "{""type"":""group"",""id"":""g$i"",""logic"":""and"",""children"":[$deep]}" }
    $v = Call-Api POST '/api/v1/rules/validate' "{""definition"":{""schemaVersion"":1,""rootEntity"":""employee"",""condition"":$deep}}" 'viewer'
    Check 'depth limit enforced' ($v.Json.valid -eq $false -and $v.Raw -match 'RULE_LIMITS_EXCEEDED') $v.Raw.Substring(0, [Math]::Min(160, $v.Raw.Length))
    Check 'employees table intact after attacks' ((Sql-Scalar 'SELECT COUNT(*) FROM biz.Employees') -eq $before)
    Check 'viewer cannot create rules (403)' ((Call-Api POST '/api/v1/rules' (Rule-Body 'x' $condOr) 'viewer').Status -eq 403)
    Check 'viewer cannot run rules (403)' ((Call-Api POST '/api/v1/rules/11111111-0000-0000-0000-000000000001/runs' $null 'viewer').Status -eq 403)
    $sqlView = Call-Api GET '/api/v1/rules/11111111-0000-0000-0000-000000000003/sql' $null 'admin'
    Check 'compiled SQL is parameterized (admin view)' ($sqlView.Status -eq 200 -and $sqlView.Json.sql -match '@p0' -and $sqlView.Json.sql -notmatch "N'A'") ''
    Log "Compiled SQL sample:`n$($sqlView.Json.sql)`n$($sqlView.Json.parameters -join "`n")"
    $nf = Call-Api GET '/api/v1/rules/00000000-0000-0000-0000-000000000000'
    Check 'unknown rule -> 404 ProblemDetails' ($nf.Status -eq 404 -and $nf.Json.code -eq 'NOT_FOUND')
    $bad = Call-Api POST '/api/v1/rules' (Rule-Body '' $condOr)
    Check 'empty name -> 400 with Hebrew message' ($bad.Status -eq 400 -and $bad.Raw -match 'NAME_REQUIRED')
    $search = Call-Api GET "/api/v1/runs/$($res.RunId)/violations?search=$([uri]::EscapeDataString('גבוה'))&pageSize=5"
    Check 'violations search endpoint works' ($search.Status -eq 200)
}

# =====================================================================
Section 'PYTHON AI SERVICE'
$ai = Join-Path $root 'ai-service'
$venvPy = Join-Path $ai '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPy)) { $r = Run-Cmd 'create venv' 'python' @('-m', 'venv', '.venv') $ai }
$r = Run-Cmd 'pip install' $venvPy @('-m', 'pip', 'install', '-q', '-r', 'requirements.txt') $ai
Check 'pip install -r requirements.txt' ($r.Code -eq 0)
$r = Run-Cmd 'pytest' $venvPy @('-m', 'pytest', '-q') $ai
$m = [regex]::Match($r.Out, '(\d+) passed')
Check 'python tests' ($r.Code -eq 0) $(if ($m.Success) { "$($m.Groups[1].Value) passed" } else { 'see log' })
if ($r.Code -eq 0 -or (Test-Path $venvPy)) {
    $procs.ai = Start-Process -FilePath $venvPy -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--port', "$aiPort") -WorkingDirectory $ai `
        -RedirectStandardOutput (Join-Path $qa 'ai.out.log') -RedirectStandardError (Join-Path $qa 'ai.err.log') -PassThru -WindowStyle Hidden
    $aiUp = Wait-Url "http://127.0.0.1:$aiPort/health" 30
    Check 'AI service starts (/health)' $aiUp
    if ($up -and $aiUp) {
        $st = Call-Api GET '/api/v1/ai/status'
        Check 'API sees AI service as available' ($st.Json.available -eq $true) $st.Raw
        Check 'AI status reports provider type (isLlm field present)' ($null -ne $st.Json.isLlm) $st.Raw
        # deterministic start: pending suggestions from earlier runs would be (correctly) skipped as duplicates
        [void](Sql-Scalar "DELETE FROM dq.AiSuggestion WHERE Status = N'Proposed'; SELECT @@ROWCOUNT")
        $gen = Call-Api POST '/api/v1/ai/suggestions/generate' '{"maxSuggestions":8}'
        Check 'generate suggestions' ($gen.Status -eq 200 -and $gen.Json.proposed -gt 0) $gen.Raw
        $gen2 = Call-Api POST '/api/v1/ai/suggestions/generate' '{"maxSuggestions":8}'
        Check 'generating again adds no duplicates of pending suggestions' ($gen2.Status -eq 200 -and [int]$gen2.Json.proposed -eq 0 -and [int]$gen2.Json.duplicates -gt 0) "proposed=$($gen2.Json.proposed) duplicates=$($gen2.Json.duplicates)"
        $list = Call-Api GET '/api/v1/ai/suggestions?status=Proposed'
        $items = @($list.Json)
        Check 'every proposed suggestion passed .NET validation (has summary)' ($items.Count -gt 0 -and @($items | Where-Object { -not $_.summaryHe }).Count -eq 0) "count=$($items.Count)"
        Check 'every suggestion is tagged with its source (llm/local) and business field names' ($items.Count -gt 0 -and @($items | Where-Object { -not $_.source -or @($_.involvedFields).Count -eq 0 }).Count -eq 0)
        foreach ($s in $items) { Log "  suggestion: [$($s.severity)] $($s.title) | $($s.evidence) | $($s.summaryHe)" }
        if ($items.Count -gt 0) {
            $acc = Call-Api POST "/api/v1/ai/suggestions/$($items[0].id)/accept" '{}'
            Check 'accept suggestion -> Draft rule with origin AI' ($acc.Status -eq 200 -and $acc.Json.status -eq 'Draft' -and $acc.Json.origin -eq 'AI') $acc.Raw.Substring(0, [Math]::Min(200, $acc.Raw.Length))
            if ($acc.Status -eq 200) {
                $res = Run-Rule $acc.Json.id
                Check 'accepted AI rule runs successfully' (-not $res.Error) "violations=$($res.Run.violationCount) $($res.Error)"
            }
        }
    }
    # resilience: stop the AI service, the rest must keep working
    if ($procs.ai) { Stop-Process -Id $procs.ai.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
    if ($up) {
        Check 'AI down: status available=false' ((Call-Api GET '/api/v1/ai/status').Json.available -eq $false)
        $g = Call-Api POST '/api/v1/ai/suggestions/generate' '{"maxSuggestions":3}'
        Check 'AI down: generate -> 503 AI_UNAVAILABLE' ($g.Status -eq 503 -and $g.Json.code -eq 'AI_UNAVAILABLE') "status=$($g.Status)"
        $res = Run-Rule '11111111-0000-0000-0000-000000000003'
        Check 'AI down: rules still run' (-not $res.Error)
    }
    # restart AI for UI testing
    $procs.ai = Start-Process -FilePath $venvPy -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--port', "$aiPort") -WorkingDirectory $ai `
        -RedirectStandardOutput (Join-Path $qa 'ai.out.log') -RedirectStandardError (Join-Path $qa 'ai.err.log') -PassThru -WindowStyle Hidden
}

# =====================================================================
if (-not $SkipFrontend) {
    Section 'ANGULAR'
    $fe = Join-Path $root 'frontend'
    # Proxied / filtered networks may drop idle connections: fewer sockets, long timeouts, retries.
    # These are CLI flags only - package.json / package-lock.json are not touched.
    $npmArgs = @('install', '--no-audit', '--no-fund', '--prefer-offline', '--maxsockets=4',
        '--fetch-timeout=600000', '--fetch-retries=6', '--fetch-retry-mintimeout=20000', '--fetch-retry-maxtimeout=180000')
    $r = Run-Cmd 'npm install' 'npm.cmd' $npmArgs $fe
    if ($r.Code -ne 0) {
        Write-Host 'npm install failed - retrying once (packages already downloaded are reused from cache)' -ForegroundColor Yellow
        $r = Run-Cmd 'npm install (retry)' 'npm.cmd' $npmArgs $fe
    }
    Check 'npm install' ($r.Code -eq 0)
    $r = Run-Cmd 'ng build' 'npx.cmd' @('ng', 'build', '--configuration', 'development') $fe
    Check 'ng build' ($r.Code -eq 0)
    if ($r.Code -eq 0) {
        $webArgs = @('ng', 'serve', '--port', "$webPort")
        if ($apiPort -ne 5080) {
            $proxyFile = Join-Path $qa 'proxy.qa.json'
            Set-Content $proxyFile ('{ "/api": { "target": "' + $base + '", "secure": false, "changeOrigin": true } }') -Encoding ASCII
            $webArgs += @('--proxy-config', "`"$proxyFile`"")
        }
        $procs.web = Start-Process -FilePath 'npx.cmd' -ArgumentList $webArgs -WorkingDirectory $fe `
            -RedirectStandardOutput (Join-Path $qa 'web.out.log') -RedirectStandardError (Join-Path $qa 'web.err.log') -PassThru -WindowStyle Hidden
        $webUp = Wait-Url "http://localhost:$webPort/" 120
        Check "Angular dev server starts (http://localhost:$webPort)" $webUp
        if ($webUp) {
            try { $px = Invoke-WebRequest -Uri "http://localhost:$webPort/api/v1/catalog/operators" -Headers @{ 'X-Demo-User' = 'viewer' } -UseBasicParsing; Check 'Angular proxy -> API works' ($px.StatusCode -eq 200) } catch { Check 'Angular proxy -> API works' $false $_.Exception.Message }
        }
    }
}

# =====================================================================
Section 'CLEANUP OF QA TEST DATA'
# tests clean up after themselves: remove only the rules this run created and the pending suggestions
$qaRuleIds = @()
if ($created -and $created.Json.id) { $qaRuleIds += [string]$created.Json.id }
if ($acc -and $acc.Status -eq 200 -and $acc.Json.id) { $qaRuleIds += [string]$acc.Json.id }
try {
    $idList = ($qaRuleIds | ForEach-Object { "'" + ([Guid]$_).ToString() + "'" }) -join ','
    $cleanSql = "SET XACT_ABORT ON; BEGIN TRAN; "
    if ($idList) {
        $cleanSql += "UPDATE dq.AiSuggestion SET AcceptedRuleId = NULL WHERE AcceptedRuleId IN ($idList); " +
            "DELETE v FROM dq.RuleRunViolation v JOIN dq.RuleRun rr ON rr.Id = v.RunId WHERE rr.RuleId IN ($idList); " +
            "DELETE FROM dq.RuleRun WHERE RuleId IN ($idList); DELETE FROM dq.RuleVersion WHERE RuleId IN ($idList); " +
            "DELETE FROM dq.[Rule] WHERE Id IN ($idList); "
    }
    $cleanSql += "DELETE FROM dq.AiSuggestion WHERE Status = N'Proposed'; COMMIT; SELECT COUNT(*) FROM dq.[Rule];"
    $left = Sql-Scalar $cleanSql
    Check 'QA test data removed (rules created by this run + pending suggestions)' $true "rules left: $left"
} catch { Check 'QA test data removed' $false $_.Exception.Message }

# =====================================================================
Section 'SUMMARY'
if ($StopServices) { foreach ($p in $procs.Values) { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } ; Log 'Services stopped.' }
else { Log "Services left running for UI testing. PIDs: $(( $procs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value.Id)" }) -join ', ')"; Log 'Stop later with: powershell -File .\qa\stop-services.ps1' }
$summary = @("QA summary $(Get-Date -Format s)", "PASS: $script:pass   FAIL: $script:fail", '') + $script:results
Set-Content -Path $summaryFile -Value $summary -Encoding UTF8
Log "PASS: $script:pass   FAIL: $script:fail"
Log "Full log: $log"
