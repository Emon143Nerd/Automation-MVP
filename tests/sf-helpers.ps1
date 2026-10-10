# tests/sf-helpers.ps1 - shared helpers for SalesFixr tests.
# Load in each PowerShell window (note the dot + space):
#     cd F:\Agency\Automation_MVP
#     . .\tests\sf-helpers.ps1
# Secrets are read from infra\.env, never typed or pasted.

$SfRoot  = Split-Path -Parent $PSScriptRoot
$SfEnv   = Join-Path $SfRoot "infra\.env"
$SfBase  = "http://localhost:5678"

function Get-SfEnv($name) {
  $line = Get-Content $SfEnv | Where-Object { $_ -match "^$name=" } | Select-Object -First 1
  if ($line) { ($line -replace "^$name=", "").Trim() } else { "" }
}

$toolToken     = Get-SfEnv "SF_TOOL_TOKEN"
$internalToken = Get-SfEnv "SF_INTERNAL_TOKEN"        # Milestone G; empty before that
$SfHeaders = @{}
if ($internalToken) { $SfHeaders["x-sf-internal-token"] = $internalToken }

# Inbound test channel (WF-01 must be Published, see Milestone D3)
$url = "$SfBase/webhook/salesfixr/v1/inbound/test"

function New-TestPhone { "+1212555" + (Get-Random -Minimum 1000 -Maximum 9999) }

# Returns the full WF-01 response object.
function Send-SFRaw($phone, $msg) {
  $body = @{ channel = "test"; phone = $phone; message = $msg } | ConvertTo-Json
  Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -Headers $SfHeaders -Body $body -TimeoutSec 90
}

# Prints one line: route, action status, reply.
function Send-SF($phone, $msg) {
  try {
    $r = Send-SFRaw $phone $msg
    "{0,-18} {1,-22} {2}" -f $r.ai.route, $r.ai.action_status, $r.reply_text
  } catch {
    "HTTP $($_.Exception.Response.StatusCode.value__): $($_.ErrorDetails.Message)"
  }
}

# Calls a tool directly. Example:
#   Invoke-Tool get_schedule @{actor_role="owner"} @{date="2026-10-12"}
function Invoke-Tool($name, $context, $toolArgs) {
  $context.correlation_id = "manual-" + (Get-Random)
  $context.tenant_slug = "demo_clinic"
  $payload = @{ auth = @{ tool_token = $toolToken }; context = $context; args = $toolArgs } | ConvertTo-Json -Depth 6
  try {
    Invoke-RestMethod -Method Post -ContentType "application/json" -Body $payload `
      -Uri "$SfBase/webhook/salesfixr/v1/tool/$name" | ConvertTo-Json -Depth 8
  } catch {
    "HTTP $($_.Exception.Response.StatusCode.value__): $($_.ErrorDetails.Message)"
  }
}

# Milestone G: send a Messenger webhook event signed exactly like Meta does.
#   Send-MessengerEvent $psid "m_test_123" "hello"
#   Send-MessengerEvent $psid "m_test_124" "hello" -BadSignature
function Send-MessengerEvent($psid, $mid, $text, [switch]$BadSignature) {
  $secret = Get-SfEnv "SF_META_APP_SECRET"
  $page   = Get-SfEnv "SF_META_PAGE_ID"
  $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $obj = @{ object = "page"; entry = @(@{ id = $page; time = $ts; messaging = @(@{
           sender = @{ id = $psid }; recipient = @{ id = $page }; timestamp = $ts;
           message = @{ mid = $mid; text = $text } }) }) }
  $json  = $obj | ConvertTo-Json -Depth 8 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $hmac  = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (,[Text.Encoding]::UTF8.GetBytes($secret))
  $sig   = "sha256=" + (($hmac.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
  if ($BadSignature) { $sig = "sha256=" + ("0" * 64) }
  $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$SfBase/webhook/salesfixr/v1/inbound/messenger" `
         -ContentType "application/json" -Headers @{ "x-hub-signature-256" = $sig } -Body $bytes
  "HTTP $($r.StatusCode)  mid=$mid  $(if ($BadSignature) { '(forged signature)' } else { '(signed)' })"
}

Write-Host "SalesFixr helpers loaded. Internal token: $(if ($internalToken) { 'set' } else { 'not set (fine before Milestone G)' })"
