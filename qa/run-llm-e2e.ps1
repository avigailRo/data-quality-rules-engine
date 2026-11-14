<#
.SYNOPSIS
  Real end-to-end proof of the AI bonus with a live LLM (Gemini via its OpenAI-compatible endpoint):
  Metadata -> LLM -> Recommendation -> Validation -> Human approval -> Saved rule -> Execution,
  plus a fallback test with a deliberately invalid key.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\qa\run-llm-e2e.ps1
  (asks for the API key with hidden input; optional: -Model gemini-2.5-flash  -SkipBuild)

  The key is kept only in this PowerShell process and in the AI service process it starts.
  It is never written to disk, never passed on a command line and never logged.
  Log: qa\llm-e2e-log.txt
#>
param(
    [string]$BaseUrl = 'https://generativelanguage.googleapis.com/v1beta/openai',
    [string]$Model = '',
    [string]$Server = '.\SQLEXPRESS',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$qa = $PSScriptRoot
$log = Join-Path $qa 'llm-e2e-log.txt'
$base = 'http://localhost:5080'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Set-Content -Path $log -Value "LLM E2E run $(Get-Date -Format s)" -Encoding UTF8
$script:pass = 0; $script:fail = 0; $script:secret = $null; $script:aiPort = 8000
trap { Log "[FAIL] SCRIPT ERROR: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"; $script:fail++; continue }

function Scrub([string]$t) { if ($script:secret -and $t) { return $t.Replace($script:secret, '***') } return $t }
function Log([string]$msg) { $m = Scrub $msg; Add-Content -Path $log -Value $m -Encoding UTF8; Write-Host $m }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; $tag = 'PASS' } else { $script:fail++; $tag = 'FAIL' }
    Log ("[$tag] $name" + $(if ($detail) { " :: $detail" } else { '' }))
}
function Section([string]$n) { Log ''; Log "==================== $n ====================" }
function Short([string]$s, [int]$n = 300) { if (-not $s) { return '' } if ($s.Length -le $n) { return $s } return $s.Substring(0, $n) + '...' }

function Call-Api([string]$method, [string]$path, [string]$body = $null, [string]$user = 'author', [int]$timeout = 240) {
    $p = @{ Uri = "$base$path"; Method = $method; Headers = @{ 'X-Demo-User' = $user }; UseBasicParsing = $true; TimeoutSec = $timeout }
    if ($body) { $p['Body'] = [Text.Encoding]::UTF8.GetBytes($body); $p['ContentType'] = 'application/json; charset=utf-8' }
    try {
        $r = Invoke-WebRequest @p
        $content = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        $json = $null
        if ($content) {
            try {
                if ($content.TrimStart().StartsWith('[')) { $json = @($content | ConvertFrom-Json | ForEach-Object { $_ }) }
                else { $json = $content | ConvertFrom-Json }
            } catch {}
        }
        return @{ Status = [int]$r.StatusCode; Json = $json; Raw = $content }
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
function Sql-Scalar([string]$sql) {
    $c = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=DataControls;Integrated Security=True;TrustServerCertificate=True")
    $c.Open(); try { $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; return $cmd.ExecuteScalar() } finally { $c.Close() }
}
function Stop-Port([int]$port) {
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
}
function Stop-Ai([int]$port = $script:aiPort) {
    # venv python.exe on Windows is a launcher with a child process: stop every uvicorn of this project, then the port owner
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'uvicorn' -and $_.CommandLine -match 'app\.main:app' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 20; $i++) {
        $owners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
        if ($owners.Count -eq 0) { return $true }
        $owners | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Start-Ai([hashtable]$envVars, [string]$tag) {
    if (-not (Stop-Ai)) { Log "[FAIL] port $($script:aiPort) is still in use by another process - cannot start the AI service"; $script:fail++; return $false }
    $names = 'DQ_LLM_PROVIDER', 'DQ_LLM_BASE_URL', 'DQ_LLM_MODEL', 'DQ_LLM_API_KEY', 'DQ_LLM_TIMEOUT_SECONDS', 'DQ_LLM_REASONING_EFFORT', 'DQ_LLM_CA_BUNDLE', 'DQ_LLM_FALLBACK_MODELS'
    foreach ($n in $names) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    foreach ($k in $envVars.Keys) { Set-Item "Env:$k" $envVars[$k] }   # inherited by the child process only
    $aiDir = Join-Path $root 'ai-service'
    $py = Join-Path $aiDir '.venv\Scripts\python.exe'
    $p = Start-Process -FilePath $py -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--port', "$($script:aiPort)") -WorkingDirectory $aiDir `
        -RedirectStandardOutput (Join-Path $qa "ai-$tag.out.log") -RedirectStandardError (Join-Path $qa "ai-$tag.err.log") -PassThru -WindowStyle Hidden
    foreach ($n in $names) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }   # do not leave the key in this shell's env
    $up = Wait-Url "http://127.0.0.1:$($script:aiPort)/health" 40
    Start-Sleep -Seconds 1
    if ($p.HasExited) {
        Log "[FAIL] AI service ($tag) exited right after start: $(Short (Get-Content (Join-Path $qa "ai-$tag.err.log") -Raw -ErrorAction SilentlyContinue) 600)"
        $script:fail++; return $false
    }
    return $up
}

# =====================================================================
Section 'API KEY'
# Regular paste (Ctrl+V or right-click). A plain prompt is used because a hidden prompt in Windows PowerShell
# turns Ctrl+V into a control character. The screen is cleared right after, and the key is never logged.
for ($try = 1; $try -le 3 -and -not $script:secret; $try++) {
    $typed = Read-Host 'Paste the Gemini API key and press Enter'
    $candidate = ([string]$typed -replace '[\x00-\x20\x7F]', '')
    Clear-Host
    if ($candidate.Length -ge 20) { $script:secret = $candidate }
    else { Write-Host "No valid key found (got $($candidate.Length) characters). Paste the key again." -ForegroundColor Yellow }
}
if (-not $script:secret) { Log 'No valid key entered - stopping.'; exit 1 }
Log "key received (length $($script:secret.Length), not logged)"

# =====================================================================
Section 'PROVIDER REACHABILITY'
$models = @()
try {
    $m = Invoke-RestMethod -Uri "$BaseUrl/models" -Headers @{ Authorization = "Bearer $($script:secret)" } -TimeoutSec 30
    $models = @($m.data | ForEach-Object { ([string]$_.id) -replace '^models/', '' })
    Check 'LLM endpoint reachable and key accepted' ($models.Count -gt 0) "$($models.Count) models"
} catch {
    $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    $detail = $_.Exception.Message
    try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $detail += ' ' + $sr.ReadToEnd() } catch {}
    if ($code -in 400, 401, 403) {
        Check 'LLM endpoint reachable and key accepted' $false (Short $detail 400)
        Log 'Stopping: the key was rejected (wrong key, key without Gemini API access, or unsupported region).'
        exit 1
    }
    if ($code -eq 0) {
        Check 'LLM endpoint reachable' $false (Short $detail 400)
        Log 'Stopping: no HTTP answer from the model endpoint (network/filter, TLS, or a local error - see the message above).'
        exit 1
    }
    Log "model list not available (HTTP $code) - continuing with a default model; the E2E calls below are the real test"
    if (-not $Model) { $Model = 'gemini-flash-latest' }
}
if (-not $Model) {
    $prefer = @('gemini-flash-latest') + @($models | Where-Object { $_ -match '^gemini-\d+(\.\d+)?-flash$' } | Sort-Object { [double](($_ -replace '^gemini-', '') -replace '-flash$', '') } -Descending)
    $Model = @($prefer | Where-Object { $models -contains $_ }) | Select-Object -First 1
    if (-not $Model) { $Model = @($models | Where-Object { $_ -match 'flash' -and $_ -notmatch 'lite|image|tts|audio|live|embedding' }) | Select-Object -First 1 }
}
# backups if the main model is overloaded (HTTP 503/429): other stable Flash models from the same account
$fallbackModels = @($models | Where-Object { $_ -ne $Model -and $_ -match '^gemini-\d+(\.\d+)?-flash(-lite)?$' } |
    Sort-Object { [double](($_ -replace '^gemini-', '') -replace '-flash(-lite)?$', '') } -Descending | Select-Object -First 3)
Check 'model selected' ([bool]$Model) "$Model (backups: $($fallbackModels -join ', '))"
if (-not $Model) { exit 1 }

# =====================================================================
Section 'START SERVICES (API + AI service with the LLM)'
Stop-Port 5080; Start-Sleep -Seconds 1
# old processes from an earlier (elevated) run may hold 5080 - then run this API on a free port
$apiPort = 5080
if (@(Get-NetTCPConnection -LocalPort 5080 -State Listen -ErrorAction SilentlyContinue).Count -gt 0) {
    foreach ($cand in 5090..5110) { if (@(Get-NetTCPConnection -LocalPort $cand -State Listen -ErrorAction SilentlyContinue).Count -eq 0) { $apiPort = $cand; break } }
    Log "port 5080 is held by a process this window cannot stop - this API runs on $apiPort"
}
$base = "http://localhost:$apiPort"
if (-not (Stop-Ai 8000)) {
    # a process this shell cannot stop (e.g. started from an elevated window) holds 8000 - use a free port instead
    $owner = @(Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue)[0].OwningProcess
    $pinfo = Get-Process -Id $owner -ErrorAction SilentlyContinue
    Log "port 8000 is held by PID $owner ($($pinfo.ProcessName)) which cannot be stopped from this window - using another port"
    foreach ($cand in 8010..8030) { if (@(Get-NetTCPConnection -LocalPort $cand -State Listen -ErrorAction SilentlyContinue).Count -eq 0) { $script:aiPort = $cand; break } }
}
Log "AI service port: $($script:aiPort)" 
$backend = Join-Path $root 'backend'
if (-not $SkipBuild) {
    Push-Location $backend
    $out = & dotnet build DataControls.slnx -c Debug -nologo -clp:ErrorsOnly 2>&1 | Out-String
    $code = $LASTEXITCODE; Pop-Location
    Check 'dotnet build' ($code -eq 0) $(if ($code -ne 0) { Short $out 1500 } else { '' })
    if ($code -ne 0) { exit 1 }
}
$aiDir = Join-Path $root 'ai-service'
& (Join-Path $aiDir '.venv\Scripts\python.exe') -c "import truststore" 2>$null
if ($LASTEXITCODE -ne 0) {
    $out = & (Join-Path $aiDir '.venv\Scripts\python.exe') -m pip install -q truststore 2>&1 | Out-String
    Log "pip install truststore: exit $LASTEXITCODE"
}
# --- TLS: export the certificates Windows trusts for the LLM host (public certs only) for Python ---
$llmHost = ([Uri]$BaseUrl).Host
$bundle = Join-Path $qa 'windows-ca-bundle.pem'
$global:chainCerts = New-Object System.Collections.ArrayList
$tlsOk = $false
try {
    $tcp = New-Object Net.Sockets.TcpClient($llmHost, 443)
    $cb = [Net.Security.RemoteCertificateValidationCallback] {
        param($sender, $cert, $chain, $errors)
        foreach ($el in $chain.ChainElements) { [void]$global:chainCerts.Add($el.Certificate) }
        return ($errors -eq [Net.Security.SslPolicyErrors]::None)
    }
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, $cb)
    $ssl.AuthenticateAsClient($llmHost); $tlsOk = $true
    $ssl.Dispose(); $tcp.Close()
} catch { Log "windows TLS chain capture: $($_.Exception.Message)" }
$all = @($global:chainCerts) + @('Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root', 'Cert:\LocalMachine\CA', 'Cert:\CurrentUser\CA' |
    ForEach-Object { Get-ChildItem $_ -ErrorAction SilentlyContinue })
$seen = @{}; $sb = New-Object Text.StringBuilder
foreach ($c in $all) {
    if (-not $c -or -not $c.RawData -or $seen.ContainsKey($c.Thumbprint)) { continue }
    $seen[$c.Thumbprint] = $true
    [void]$sb.AppendLine('-----BEGIN CERTIFICATE-----')
    [void]$sb.AppendLine([Convert]::ToBase64String($c.RawData, [Base64FormattingOptions]::InsertLineBreaks))
    [void]$sb.AppendLine('-----END CERTIFICATE-----')
}
[IO.File]::WriteAllText($bundle, $sb.ToString(), (New-Object Text.ASCIIEncoding))
$chainText = (@($global:chainCerts) | ForEach-Object { $_.Subject }) -join '  <-  '
Check 'Windows validates the LLM host certificate' $tlsOk "chain: $chainText"
Log "exported $($seen.Count) public CA certificates to $bundle"
$diag = & (Join-Path $aiDir '.venv\Scripts\python.exe') (Join-Path $qa 'tls-check.py') $llmHost $bundle 2>&1 | Out-String
Log $diag.Trim()

$apiProj = Join-Path $backend 'src\DataControls.Api'
# settings on the command line have the highest precedence (an LLM call + one repair round needs a longer timeout)
$apiArgs = @('run', '--no-build', '--project', "`"$apiProj`"", '--', '--urls', $base,
    "--Advisor:BaseUrl=http://127.0.0.1:$($script:aiPort)", '--Advisor:TimeoutSeconds=200')
$api = Start-Process -FilePath 'dotnet' -ArgumentList $apiArgs -WorkingDirectory $apiProj `
    -RedirectStandardOutput (Join-Path $qa 'api-llm.out.log') -RedirectStandardError (Join-Path $qa 'api-llm.err.log') -PassThru -WindowStyle Hidden
Check "API starts ($base)" (Wait-Url "$base/health/ready" 60)
Start-Sleep -Seconds 1
if ($api.HasExited) { Log "[FAIL] API exited right after start: $(Short (Get-Content (Join-Path $qa 'api-llm.err.log') -Raw -ErrorAction SilentlyContinue) 600)"; $script:fail++ }

$llmEnv = @{
    DQ_LLM_PROVIDER = 'openai'; DQ_LLM_BASE_URL = $BaseUrl; DQ_LLM_MODEL = $Model; DQ_LLM_API_KEY = $script:secret
    DQ_LLM_TIMEOUT_SECONDS = '90'; DQ_LLM_REASONING_EFFORT = 'low'; DQ_LLM_FALLBACK_MODELS = ($fallbackModels -join ',')
}
if ($diag -match 'windows-export-bundle: OK') { $llmEnv.DQ_LLM_CA_BUNDLE = $bundle }
Check 'AI service starts with the LLM provider' (Start-Ai $llmEnv 'llm')
$h = Invoke-RestMethod "http://127.0.0.1:$($script:aiPort)/health" -TimeoutSec 5
Check 'AI service reports a real LLM (health)' ($h.llm -eq $true -and $h.model -eq $Model) ($h | ConvertTo-Json -Compress)
$st = Call-Api GET '/api/v1/ai/status'
Check 'API status: available, isLlm=true' ($st.Json.available -eq $true -and $st.Json.isLlm -eq $true) $st.Raw

# =====================================================================
Section 'E2E: METADATA -> LLM -> VALIDATION -> APPROVAL -> SAVED RULE -> EXECUTION'
$rulesBefore = [int](Sql-Scalar 'SELECT COUNT(*) FROM dq.[Rule]')
$t0 = Get-Date
$gen = Call-Api POST '/api/v1/ai/suggestions/generate' '{"maxSuggestions":6}'
$secs = [int]((Get-Date) - $t0).TotalSeconds
Log "generate took $secs s :: $($gen.Raw)"
Check 'generate returned 200' ($gen.Status -eq 200) "status=$($gen.Status)"
Check 'answer came from the LLM (no fallback)' ($gen.Json.isLlm -eq $true -and $gen.Json.fallbackUsed -eq $false) "provider=$($gen.Json.provider) fallbackReason=$($gen.Json.fallbackReason)"
Check 'LLM proposals passed .NET validation' ([int]$gen.Json.proposed -gt 0) "proposed=$($gen.Json.proposed) invalidInDotNet=$($gen.Json.invalid) duplicates=$($gen.Json.duplicates) rejectedInPython=$($gen.Json.rejectedByAdvisor)"
$rulesAfterGenerate = [int](Sql-Scalar 'SELECT COUNT(*) FROM dq.[Rule]')
Check 'nothing saved as a rule before human approval' ($rulesAfterGenerate -eq $rulesBefore) "rules before=$rulesBefore after generate=$rulesAfterGenerate"

$list = Call-Api GET '/api/v1/ai/suggestions?status=Proposed'
$mine = @($list.Json | Where-Object { $_.batchId -eq $gen.Json.batchId })
$llmItems = @($mine | Where-Object { $_.source -eq 'llm' })
Check 'every suggestion of this batch is tagged source=llm' ($mine.Count -gt 0 -and $llmItems.Count -eq $mine.Count) "batch=$($mine.Count) llm=$($llmItems.Count)"
foreach ($s in $mine) {
    Log "  --- [$($s.severity)] $($s.title)  (source=$($s.source), model=$($s.model))"
    Log "      explanation : $($s.explanationHe)"
    Log "      evidence    : $($s.evidence)"
    Log "      fields      : $(@($s.involvedFields) -join ' | ')"
    Log "      .NET summary: $($s.summaryHe)"
    Log "      definition  : $(Short ($s.definition | ConvertTo-Json -Depth 30 -Compress) 1200)"
}
$noSql = @($mine | Where-Object { ($_.definition | ConvertTo-Json -Depth 30 -Compress) -match '(?i)"sql"|\bselect\b.+\bfrom\b|;\s*(drop|delete|update|insert)\b' }).Count -eq 0
Check 'no SQL in any LLM definition (typed AST only)' $noSql

if ($llmItems.Count -gt 0) {
    $pick = $llmItems[0]
    $acc = Call-Api POST "/api/v1/ai/suggestions/$($pick.id)/accept" '{}'
    Check 'human approval -> Draft rule with origin AI' ($acc.Status -eq 200 -and $acc.Json.status -eq 'Draft' -and $acc.Json.origin -eq 'AI') "status=$($acc.Status) rule=$($acc.Json.id) name=$($acc.Json.name)"
    $rulesAfterAccept = [int](Sql-Scalar 'SELECT COUNT(*) FROM dq.[Rule]')
    Check 'exactly one rule saved after approval' ($rulesAfterAccept -eq $rulesBefore + 1) "rules now=$rulesAfterAccept"
    if ($acc.Status -eq 200) {
        $start = Call-Api POST "/api/v1/rules/$($acc.Json.id)/runs"
        $run = $null
        if ($start.Status -eq 202) {
            for ($i = 0; $i -lt 90; $i++) {
                Start-Sleep -Milliseconds 700
                $run = (Call-Api GET "/api/v1/runs/$($start.Json.id)").Json
                if ($run.status -in @('Succeeded', 'Failed', 'TimedOut')) { break }
            }
        }
        Check 'LLM-generated rule executes on SQL Server' ($run.status -eq 'Succeeded') "status=$($run.status) violations=$($run.violationCount) $($run.errorMessage)"
        if ($run.status -eq 'Succeeded') {
            $page = (Call-Api GET "/api/v1/runs/$($start.Json.id)/violations?pageSize=5").Json
            foreach ($v in @($page.items)) { Log "      violation #$($v.recordKey) $($v.recordLabel): $(@($v.reasons | ForEach-Object { $_.textHe }) -join ' ; ')" }
        }
    }
}

# =====================================================================
Section 'FALLBACK: LLM FAILS -> LOCAL ANALYSIS STILL WORKS'
$badEnv = $llmEnv.Clone(); $badEnv.DQ_LLM_API_KEY = 'invalid-key-for-fallback-test'
Check 'AI service restarts with an invalid key' (Start-Ai $badEnv 'fallback')
$fb = Call-Api POST '/api/v1/ai/suggestions/generate' '{"maxSuggestions":3}'
Log "fallback generate :: $($fb.Raw)"
Check 'invalid key -> fallback to local analysis, still 200' ($fb.Status -eq 200 -and $fb.Json.fallbackUsed -eq $true -and $fb.Json.isLlm -eq $false) "reason=$($fb.Json.fallbackReason)"
$fbItems = @((Call-Api GET '/api/v1/ai/suggestions?status=Proposed').Json | Where-Object { $_.batchId -eq $fb.Json.batchId })
Check 'fallback suggestions are tagged source=local (never shown as LLM)' (@($fbItems | Where-Object { $_.source -ne 'local' }).Count -eq 0) "count=$($fbItems.Count) (0 is fine if all were duplicates: $($fb.Json.duplicates))"

# =====================================================================
Section 'LEAVE RUNNING FOR THE UI DEMO'
Check 'AI service restarted with the real LLM' (Start-Ai $llmEnv 'llm')
Log "API: http://localhost:5080  AI service: http://127.0.0.1:$($script:aiPort) (LLM mode, key only in that process)" 
Log 'UI: start the frontend (npx ng serve) and open http://localhost:4200 -> המלצות AI'
Log 'Stop later with: powershell -File .\qa\stop-services.ps1'
$script:secret = $null
Log ''
Log "PASS: $($script:pass)   FAIL: $($script:fail)"
Log "Log: $log"
