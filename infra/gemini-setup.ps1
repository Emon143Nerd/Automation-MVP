# SalesFixr - Milestone C0 helper
# Run from PowerShell:   cd F:\Agency\Automation_MVP\infra ; .\gemini-setup.ps1
# Does C0.2 (find model), C0.3 (smoke test JSON mode), C0.4 (write model to .env + restart n8n).
# Reads the key from infra\.env (gitignored).

$ErrorActionPreference = "Stop"
$base = "https://generativelanguage.googleapis.com/v1beta"
# Key is read from SF_GEMINI_API_KEY in infra\.env (gitignored). No pasting needed.
$envPath = Join-Path $PSScriptRoot ".env"
$keyLine = Get-Content $envPath | Where-Object { $_ -match '^SF_GEMINI_API_KEY=' } | Select-Object -First 1
$key = if ($keyLine) { ($keyLine -replace '^SF_GEMINI_API_KEY=', '').Trim().Trim('"') } else { "" }
Write-Host ("Key from .env: {0}...{1}  ({2} characters)" -f $key.Substring(0,[Math]::Min(4,$key.Length)), $key.Substring([Math]::Max(0,$key.Length-3)), $key.Length)
if ($key.Length -lt 30) { Write-Host "No key found. Open infra\.env in Notepad, put your key after SF_GEMINI_API_KEY= , save, run again." -ForegroundColor Red; exit 1 }
function Get-Err($e) {
  if ($e.ErrorDetails -and $e.ErrorDetails.Message) { return $e.ErrorDetails.Message }
  try { $sr = New-Object IO.StreamReader($e.Exception.Response.GetResponseStream()); $b = $sr.ReadToEnd(); if ($b) { return $b } } catch {}
  return $e.Exception.Message
}
$headers = @{ "x-goog-api-key" = $key }

# ---- C0.2 list Flash models -------------------------------------------
Write-Host "`n[1/3] Listing models..." -ForegroundColor Cyan
try {
  $models = (Invoke-RestMethod -Uri "$base/models?pageSize=200" -Headers $headers).models
} catch {
  Write-Host "FAILED to list models:" -ForegroundColor Red
  Write-Host (Get-Err $_)
  Write-Host "`nIf this says ACCESS_TOKEN_TYPE_UNSUPPORTED or 'API key not valid', copy this whole output and send it to Claude."
  exit 1
}
$flash = $models | Where-Object {
  $_.name -like "*flash*" -and $_.name -notmatch "preview|exp|image|tts|audio|live|thinking" -and
  $_.supportedGenerationMethods -contains "generateContent"
} | Select-Object -ExpandProperty name | ForEach-Object { $_ -replace '^models/', '' }

if (-not $flash) { Write-Host "No stable Flash model found. Send this output to Claude." -ForegroundColor Red; $models.name; exit 1 }
Write-Host "Stable Flash models available:"; $flash | ForEach-Object { "  $_" }

# ---- C0.3 smoke test each until one works -----------------------------
Write-Host "`n[2/3] Testing JSON mode..." -ForegroundColor Cyan
$body = @{
  contents = @(@{ role = "user"; parts = @(@{ text = "Can I book a cleaning tomorrow at 2?" }) })
  generationConfig = @{
    temperature = 0.2; maxOutputTokens = 2048
    responseMimeType = "application/json"
    responseSchema = @{
      type = "OBJECT"
      properties = @{
        intent         = @{ type = "STRING"; enum = @("booking","faq","unknown") }
        preferred_time = @{ type = "STRING"; nullable = $true }
      }
      required = @("intent","preferred_time")
    }
  }
} | ConvertTo-Json -Depth 10

# Try free-tier-friendly models first, then everything else; skip "omni".
$preferred = @("gemini-2.5-flash","gemini-flash-latest","gemini-2.5-flash-lite","gemini-flash-lite-latest","gemini-3.5-flash","gemini-3.5-flash-lite","gemini-3.1-flash-lite","gemini-3.6-flash","gemini-3.7-flash","gemini-3.8-flash")
$ordered = @($preferred | Where-Object { $flash -contains $_ }) + @($flash | Where-Object { $preferred -notcontains $_ -and $_ -notlike "*omni*" })
$chosen = $null
Write-Host ("Will try, in order: " + ($ordered -join ", "))
foreach ($m in $ordered) {
  Write-Host "  trying $m ..." -NoNewline
  try {
    $r = Invoke-RestMethod -Method Post -Uri "$base/models/${m}:generateContent" -Headers $headers -ContentType "application/json" -Body $body -TimeoutSec 30
    $text = ($r.candidates[0].content.parts | Where-Object { -not $_.thought } | ForEach-Object { $_.text }) -join ""
    Write-Host "  $m  ->  $text" -ForegroundColor Green
    $null = $text | ConvertFrom-Json
    $chosen = $m; break
  } catch {
    $msg = Get-Err $_
    if ($msg -match "429|Too Many|RESOURCE_EXHAUSTED") { $msg = "no free quota (429)" } elseif ($msg -match "404|NOT_FOUND|not found") { $msg = "not available to your key (404)" } else { $msg = ($msg -replace "\s+"," "); if ($msg.Length -gt 300) { $msg = $msg.Substring(0,300) } }
    Write-Host "  $m  ->  $msg" -ForegroundColor Yellow
    Start-Sleep -Seconds 2
  }
}
if (-not $chosen) { Write-Host "`nNo model passed. Copy this whole output and send it to Claude." -ForegroundColor Red; exit 1 }

# ---- C0.4 write model to .env and restart n8n -------------------------
Write-Host "`n[3/3] Using $chosen - updating .env and restarting n8n..." -ForegroundColor Cyan
$envPath = Join-Path $PSScriptRoot ".env"
$lines = Get-Content $envPath
if ($lines -match '^SF_GEMINI_MODEL=') { $lines = $lines -replace '^SF_GEMINI_MODEL=.*', "SF_GEMINI_MODEL=$chosen" }
else { $lines += "SF_GEMINI_MODEL=$chosen" }
Set-Content -Path $envPath -Value $lines -Encoding UTF8
Push-Location $PSScriptRoot; docker compose up -d; Pop-Location

Write-Host "`nDONE. C0 complete. Model: $chosen" -ForegroundColor Green
Write-Host "Next: C1 (run db/004 in Neon) and C2 (paste the same AQ. key into the n8n 'SalesFixr Gemini' Header Auth credential)."
