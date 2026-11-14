﻿# Quick probe: sends a TINY request to Gemini through two different endpoints and shows status, time and the answer.
#   A) OpenAI-compatible endpoint (what the AI service uses today)
#   B) Gemini native endpoint (generateContent) - a different path, to see whether only one of them is blocked
# The key is read once, kept in memory only, never logged. Output: qa\gemini-probe.txt
$ErrorActionPreference = 'Continue'
$out = Join-Path $PSScriptRoot 'gemini-probe.txt'
Set-Content $out "Gemini probe $(Get-Date -Format s)" -Encoding UTF8
$key = ([string](Read-Host 'Paste the Gemini API key and press Enter') -replace '[\x00-\x20\x7F]', ''); Clear-Host

function Probe([string]$name, [string]$url, [string]$body, [hashtable]$headers) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $url -Method POST -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' `
            -Headers $headers -UseBasicParsing -TimeoutSec 45
        $line = "$name : HTTP $($r.StatusCode) in $([int]$sw.Elapsed.TotalSeconds)s :: $($r.Content.Substring(0, [Math]::Min(200, $r.Content.Length)))"
    } catch {
        $code = 0; $text = $_.Exception.Message
        try { $code = [int]$_.Exception.Response.StatusCode; $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $text = $sr.ReadToEnd() } catch {}
        $line = "$name : HTTP $code in $([int]$sw.Elapsed.TotalSeconds)s :: $($text.Substring(0, [Math]::Min(300, $text.Length)))"
    }
    $line = ($line -replace "`r?`n", ' ').Replace($key, '***')
    Add-Content $out $line -Encoding UTF8; Write-Host $line
}

$compat = @{ Authorization = "Bearer $key" }
$native = @{ 'x-goog-api-key' = $key }
foreach ($model in 'gemini-flash-lite-latest', 'gemini-flash-latest') {
    Probe "A openai-compat $model" 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions' `
        (@{ model = $model; messages = @(@{ role = 'user'; content = 'Reply with the single word OK' }) } | ConvertTo-Json -Depth 5) $compat
    Probe "B native        $model" "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" `
        '{"contents":[{"parts":[{"text":"Reply with the single word OK"}]}]}' $native
}
$key = $null
Write-Host "Saved: $out"
