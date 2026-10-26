# tests/meta-setup.ps1 - Meta (Facebook Page + Instagram) setup WITHOUT logging in to Facebook.
#
# Everything here uses the credentials the asset owner sent you
# (docs/META-ACCESS-HANDOFF.md), read from infra\.env. Nothing secret is printed.
#
#   cd F:\Agency\Automation_MVP
#   . .\tests\meta-setup.ps1          # note the dot and space
#   Test-MetaAccess                   # G3.4: checks token, Page, Instagram; saves the Page token + IG id to .env
#   Set-MetaWebhooks                  # G8:   registers the webhook for Page + Instagram and subscribes the Page
#   Show-MetaWebhooks                 # G8:   shows what Meta currently has registered

. (Join-Path $PSScriptRoot "sf-helpers.ps1")

$SfGraphBase = if ($env:SF_GRAPH_BASE_OVERRIDE) { $env:SF_GRAPH_BASE_OVERRIDE } else { "https://graph.facebook.com" }

# Scopes the system user token needs (docs/META-ACCESS-HANDOFF.md section 4).
$SfRequiredScopes = @("pages_show_list", "pages_read_engagement", "pages_manage_metadata", "pages_messaging",
                      "instagram_basic", "instagram_manage_messages", "business_management")

function Set-SfEnvValue($name, $value) {
  # Writes NAME=value into infra\.env (replaces the line or appends it). UTF-8 without BOM.
  $lines = @()
  if (Test-Path $SfEnv) { $lines = @(Get-Content $SfEnv) }
  $found = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "^$name=") { $lines[$i] = "$name=$value"; $found = $true }
  }
  if (-not $found) { $lines += "$name=$value" }
  [IO.File]::WriteAllLines($SfEnv, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Graph($method, $path, [hashtable]$params) {
  # Returns @{ ok; data; error }. Error text comes from Meta, never contains the token.
  $ver = Get-SfEnv "SF_META_GRAPH_VERSION"
  if (-not $ver) { $ver = "v26.0" }
  try {
    $data = Invoke-RestMethod -Method $method -Uri "$SfGraphBase/$ver/$path" -Body $params -TimeoutSec 30
    return @{ ok = $true; data = $data; error = $null }
  } catch {
    $msg = $_.Exception.Message
    try { $e = ($_.ErrorDetails.Message | ConvertFrom-Json).error; $msg = "($($e.code)) $($e.message)" } catch {}
    return @{ ok = $false; data = $null; error = $msg }
  }
}

function Write-Check($ok, $text) {
  if ($ok) { Write-Host "  [OK]   $text" -ForegroundColor Green } else { Write-Host "  [FAIL] $text" -ForegroundColor Red }
}

function Test-MetaAccess {
  $appId  = Get-SfEnv "SF_META_APP_ID"
  $secret = Get-SfEnv "SF_META_APP_SECRET"
  $sys    = Get-SfEnv "SF_META_SYSTEM_USER_TOKEN"
  $pageId = Get-SfEnv "SF_META_PAGE_ID"
  $missing = @()
  if (-not $appId)  { $missing += "SF_META_APP_ID" }
  if (-not $secret) { $missing += "SF_META_APP_SECRET" }
  if (-not $sys)    { $missing += "SF_META_SYSTEM_USER_TOKEN" }
  if (-not $pageId) { $missing += "SF_META_PAGE_ID" }
  if ($missing.Count) { Write-Check $false ("Missing in infra\.env: " + ($missing -join ", ")); return }

  Write-Host "`n1. The token itself"
  $dbg = Invoke-Graph GET "debug_token" @{ input_token = $sys; access_token = "$appId|$secret" }
  if (-not $dbg.ok) { Write-Check $false "Meta rejected the App ID / App Secret / token: $($dbg.error)"; return }
  $d = $dbg.data.data
  Write-Check ($d.is_valid -eq $true) "Token is valid"
  Write-Check ("$($d.app_id)" -eq "$appId") "Token belongs to this app ($appId)"
  Write-Check ($d.type -eq "SYSTEM_USER") "Token type is SYSTEM_USER (is: $($d.type))"
  Write-Check ([int64]$d.expires_at -eq 0) "Token never expires"
  $have = @($d.scopes)
  $lack = @($SfRequiredScopes | Where-Object { $have -notcontains $_ })
  Write-Check ($lack.Count -eq 0) ("Scopes present" + $(if ($lack.Count) { " - missing: " + ($lack -join ", ") } else { "" }))
  if (-not $d.is_valid) { return }

  Write-Host "`n2. The Facebook Page"
  $pg = Invoke-Graph GET $pageId @{ fields = "id,name,access_token,instagram_business_account{id,username}"; access_token = $sys }
  if (-not $pg.ok) {
    Write-Check $false "Page $pageId not readable with this token: $($pg.error)"
    Write-Host "         Fix: the asset owner must assign this Page to the system user (Full control)."
    return
  }
  Write-Check $true "Page: $($pg.data.name) ($($pg.data.id))"
  Write-Check ([bool]$pg.data.access_token) "Page access token issued (needed to send messages)"
  if ($pg.data.access_token) {
    Set-SfEnvValue "SF_META_PAGE_TOKEN" $pg.data.access_token
    Write-Host "         saved to infra\.env as SF_META_PAGE_TOKEN (not shown)"
  }

  Write-Host "`n3. The Instagram account"
  $ig = $pg.data.instagram_business_account
  if (-not $ig) {
    Write-Check $false "No Instagram professional account is linked to this Page"
    Write-Host "         Fix (asset owner): Instagram must be Business or Creator, and linked to this Page"
    Write-Host "         (Page settings > Linked accounts > Instagram). Messenger still works without it."
  } else {
    Write-Check $true "Instagram: @$($ig.username) ($($ig.id))"
    Set-SfEnvValue "SF_META_IG_ACCOUNT_ID" $ig.id
    Write-Host "         saved to infra\.env as SF_META_IG_ACCOUNT_ID"
  }

  Write-Host "`n4. Paste into the Neon SQL editor:"
  $igSql = if ($ig) { "'$($ig.id)'" } else { "NULL" }
  Write-Host "   UPDATE clinic_settings SET messenger_page_id = '$pageId', instagram_account_id = $igSql"
  Write-Host "    WHERE tenant_id = (SELECT id FROM tenants WHERE slug = 'demo_clinic') RETURNING messenger_page_id, instagram_account_id;"
}

function Set-MetaWebhooks {
  $appId  = Get-SfEnv "SF_META_APP_ID"
  $secret = Get-SfEnv "SF_META_APP_SECRET"
  $pageId = Get-SfEnv "SF_META_PAGE_ID"
  $pageTk = Get-SfEnv "SF_META_PAGE_TOKEN"
  $verify = Get-SfEnv "SF_META_VERIFY_TOKEN"
  $base   = Get-SfEnv "SF_PUBLIC_BASE_URL"
  if (-not ($appId -and $secret -and $pageId -and $pageTk -and $verify -and $base)) {
    Write-Check $false "Run Test-MetaAccess first, and set SF_META_VERIFY_TOKEN + SF_PUBLIC_BASE_URL in infra\.env"; return
  }
  $callback = "$base/webhook/salesfixr/v1/inbound/messenger"
  Write-Host "Callback URL: $callback"
  Write-Host "(Meta calls it right now to verify: ngrok must be running and WF-11 Published.)`n"

  foreach ($obj in @("page", "instagram")) {
    $r = Invoke-Graph POST "$appId/subscriptions" @{
      object = $obj; callback_url = $callback; fields = "messages,messaging_postbacks"
      verify_token = $verify; include_values = "true"; access_token = "$appId|$secret" }
    Write-Check $r.ok ("App webhook for '$obj' messages" + $(if (-not $r.ok) { ": $($r.error)" } else { "" }))
  }

  $s = Invoke-Graph POST "$pageId/subscribed_apps" @{ subscribed_fields = "messages,messaging_postbacks"; access_token = $pageTk }
  Write-Check $s.ok ("Page subscribed to the app (delivers Messenger + Instagram DMs)" + $(if (-not $s.ok) { ": $($s.error)" } else { "" }))
}

function Show-MetaWebhooks {
  $appId  = Get-SfEnv "SF_META_APP_ID"
  $secret = Get-SfEnv "SF_META_APP_SECRET"
  $pageId = Get-SfEnv "SF_META_PAGE_ID"
  $pageTk = Get-SfEnv "SF_META_PAGE_TOKEN"
  $a = Invoke-Graph GET "$appId/subscriptions" @{ access_token = "$appId|$secret" }
  if ($a.ok) {
    foreach ($x in @($a.data.data)) {
      Write-Host ("  app  {0,-10} active={1,-5} {2}  fields: {3}" -f $x.object, $x.active, $x.callback_url, (@($x.fields | ForEach-Object { $_.name }) -join ","))
    }
  } else { Write-Check $false "App subscriptions: $($a.error)" }
  $p = Invoke-Graph GET "$pageId/subscribed_apps" @{ access_token = $pageTk }
  if ($p.ok) {
    foreach ($x in @($p.data.data)) { Write-Host ("  page app {0} ({1})  fields: {2}" -f $x.name, $x.id, (@($x.subscribed_fields) -join ",")) }
  } else { Write-Check $false "Page subscriptions: $($p.error)" }
}

Write-Host "Meta helpers loaded: Test-MetaAccess, Set-MetaWebhooks, Show-MetaWebhooks"
