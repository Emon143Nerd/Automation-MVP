# Milestone G — Real Messenger Channel

**Goal:** pick up your phone, message your Facebook Page, and get the same
behaviour you've been testing with PowerShell: real availability, a real booking,
a Telegram ping, an owner-style answer when *you* ask. The master-plan demo, for
real.

**Why now:** everything behind the front door is finished and tested. A, B and
C–F were deliberately built on the `test` channel, so every problem so far was a
logic problem, never a Facebook problem. G adds only the channel. If something
breaks now, it's in the new pieces, and the audit log tells you which.

**Time:** about 3 hours. Roughly one of those is Meta's dashboard.

**Prerequisite:** Milestone F green: the F8 demo passes on the test channel.

**Acceptance test (master plan):** message your Page from your phone, get a real
reply. Then run master-plan steps 1–7 from the phone.

---

## G0. What gets built

```
Your phone ──► Facebook ──► Meta servers ──► https://<you>.ngrok-free.app ──► n8n on your PC
                                                    │
     ┌──────────────────────────────────────────────┘
     ▼
SF WF-11 Messenger Channel                                   (new: the Messenger adapter)
  GET  /inbound/messenger → verify token  → echo challenge          (one-time handshake)
  POST /inbound/messenger → answer 200 immediately
        → CRY Sign Raw Body → FN Verify And Split Events     signature check, one item per message
        → LOOP Each Message:
             PG Claim Event          ← Meta retries; each message id is processed once
             HTTP Call WF-01         ← the brain you already built, unchanged
             SUB Call WF-09 Send     ← reply goes back out via the Send API

SF WF-01 Inbound Gateway  + WH Inbound Normalized             (new internal entrance)
SF WF-09 Outbound Router                                      (new: the only workflow that knows how to send)
```

**Why a separate Messenger workflow instead of adding Facebook to WF-01:**

- **Meta wants a fast `200`.** If a webhook takes too long, Meta retries it and
  eventually disables the subscription. The AI + tools take 3–10 seconds. WF-11
  answers instantly, then does the work.
- **Meta batches.** One webhook call can carry several messages. WF-11 splits them
  and feeds them to WF-01 one at a time, so WF-01's `.first()` logic stays correct.
- **WF-01 stays channel-free.** It receives the standard envelope it has always
  received. When WhatsApp comes later, it gets its own small adapter workflow, and
  WF-01, WF-02 and the tools don't change. That's the "replaceable providers"
  promise from the master plan, now for channels.

**Why WF-09 exists:** in C–F the reply travelled back in the HTTP response, which
is all the test channel needs. Messenger replies must be *sent* with a separate API
call. WF-09 is the one place that knows how to do that, per channel. Milestone H's
reminders will use it too.

---

## G1. Lock the internal doors first

Until now n8n was only reachable from your PC. **From G3 on, ngrok puts it on the
internet.** Before that happens:

| URL | Today | Problem once public | Fix |
|---|---|---|---|
| `/webhook/salesfixr/v1/tool/*` | Body token (E) | none | already protected |
| `/webhook/salesfixr/v1/inbound/test` | Open | Anyone could send messages *as any phone number*, including your owner number, and get **owner** answers | **Header token**, below |
| `/webhook/salesfixr/v1/inbound/normalized` (new, G7) | — | Same | Header token |
| `/webhook/salesfixr/v1/inbound/messenger` (new) | — | Forged Facebook events | Meta's signature check (G6) |
| The n8n editor itself | Your n8n login | Brute-force attempts | Strong password + 2FA, below |

### G1.1 The internal token

Make a new random string (PowerShell):

```powershell
-join ((48..57)+(65..90)+(97..122) | Get-Random -Count 40 | % {[char]$_})
```

Put it in `infra/.env`:

```
SF_INTERNAL_TOKEN=paste-it-here
```

(The test scripts read it from there. n8n itself reads it from the credential below,
so no `docker compose` restart is needed for this one.)

**n8n credential:** Credentials → Create → **Header Auth**.

| Field | Value |
|---|---|
| Credential name | `SalesFixr Internal` |
| Name | `x-sf-internal-token` |
| Value | the same string |

### G1.2 Protect WF-01's test webhook

Open **SF WF-01 Inbound Gateway** → `WH-Inbound-Test` → **Authentication: Header
Auth** → credential `SalesFixr Internal`. **Save → Publish.**

Now any request without the header gets `403` before a single node runs.

### G1.3 Update the test scripts

From now on every PowerShell test must send the header. I've put shared helpers in
your project at `tests\sf-helpers.ps1`: `Send-SF`, `Invoke-Tool`, `New-TestPhone`.
They read both tokens from `.env`, so nothing secret is ever typed or pasted. Load
them in each new PowerShell window:

```powershell
cd F:\Agency\Automation_MVP
. .\tests\sf-helpers.ps1          # note the dot and space at the start
Send-SF (New-TestPhone) "Are you open on Saturday?"
```

`tests\d-router.ps1` uses the same helpers, so it keeps working.

**Check:** send without the header and confirm you're refused:

```powershell
Invoke-RestMethod -Method Post -Uri "http://localhost:5678/webhook/salesfixr/v1/inbound/test" `
  -ContentType "application/json" -Body '{"channel":"test","phone":"+15550000001","message":"hi"}'
```

Expect `403 Forbidden` (or "Authorization data is wrong!").

### G1.4 Protect the editor

n8n → bottom-left your name → **Settings → Personal**:

- A long password, not reused anywhere.
- **Enable two-factor authentication** (it's in the same page, with an
  authenticator app).

The editor will be reachable at your ngrok address while the tunnel runs. Run
ngrok only while you're testing or demoing, not 24/7 from your PC.

---

## G2. ngrok: the public address  (doc 01 §4)

Follow `docs/01-ACCOUNTS-AND-FREE-TIERS.md` §4. Then:

```
SF_PUBLIC_BASE_URL=https://your-domain.ngrok-free.app
```

in `infra/.env` (https, no trailing slash).

**Leave `WEBHOOK_URL=http://localhost:5678` as it is.** It only controls the URLs
n8n *displays* and the OAuth redirect address. Webhooks are reachable through the
tunnel either way. Changing it would change your Google Calendar redirect URL and
force you to redo E1.2.

Start the tunnel (keep this window open while testing):

```powershell
ngrok http 5678 --url=https://your-domain.ngrok-free.app
```

(Older ngrok versions use `--domain=your-domain.ngrok-free.app` instead of `--url`.)

**Check:** `https://your-domain.ngrok-free.app` in a browser shows the n8n sign-in
page. ngrok's free plan may first show a "You are about to visit…" warning page
in browsers. That's normal, and it doesn't affect Meta's server-to-server calls.

---

## G3. Meta app, page token and secrets  (doc 01 §7, steps 1–6)

Follow `docs/01-ACCOUNTS-AND-FREE-TIERS.md` §7 **steps 1–6 only**. Step 7 (the
webhook) comes in G8, once the workflow exists. Extra notes:

- **Graph API version.** `.env` still says `v21.0`. Meta retires versions about two
  years after release, so use the current one shown in your app's dashboard (*App
  settings → Advanced → Upgrade API version*). At the time of writing that's
  **v26.0**:
  ```
  SF_META_GRAPH_VERSION=v26.0
  ```
- **Long-lived page token.** The token shown when you first click *Generate token*
  for a Page in the Messenger settings is normally long-lived for Pages you admin.
  If replies start failing with `Error validating access token` after an hour,
  generate it again from **Messenger → Settings → Access Tokens**, not from the
  Graph API Explorer (which gives short-lived tokens).
- **Development mode is fine.** Only people with a role on the app (you, testers)
  and the Page's admins can talk to the bot. That's exactly right for building and
  for client demos.

Put the values in `infra/.env`:

```
SF_META_APP_ID=…
SF_META_APP_SECRET=…
SF_META_PAGE_ID=…
SF_META_PAGE_TOKEN=…            (also goes into the credential below)
SF_META_VERIFY_TOKEN=sf_verify_<some random characters>
SF_META_GRAPH_VERSION=v26.0
```

Apply: `cd infra; docker compose up -d`.

### G3.1 Two n8n credentials

**Page token** (used to *send* replies). Credentials → Create → **Query Auth**:

| Field | Value |
|---|---|
| Credential name | `SalesFixr Meta Page Token` |
| Name | `access_token` |
| Value | the Page Access Token |

**App secret** (used to *verify* that incoming events really come from Meta).
Credentials → Create → **Crypto**:

| Field | Value |
|---|---|
| Credential name | `SalesFixr Meta App Secret` |
| Hmac Secret | the App Secret |

### G3.2 Tell the database which Page belongs to the clinic

```sql
UPDATE clinic_settings
   SET messenger_page_id = 'PASTE-PAGE-ID'
 WHERE tenant_id = (SELECT id FROM tenants WHERE slug = 'demo_clinic');
```

When a message arrives, WF-11 looks up *which clinic owns this Page*. With a second
clinic, its Page id goes on its own row and nothing else changes.

---

## G4. New things in this milestone — read once

### Webhook "Respond: Immediately"

So far webhooks waited for a *Respond to Webhook* node. With **Respond:
Immediately**, n8n sends `200 OK` the moment the request arrives and runs the rest
of the workflow afterwards. This is what keeps Meta happy while the AI thinks.

### Webhook "Raw Body"

Meta signs the **exact bytes** it sent. If you re-serialise the parsed JSON (key
order, spaces, `\u00e9` vs `é`), the signature no longer matches. With **Options →
Raw Body: on**, the webhook keeps the original bytes as binary data (property
`data`) next to the parsed `body`.

### Crypto node — we name it `CRY …`

*Node picker → **Crypto**.* Computes hashes and HMACs. We use **Hmac / SHA256 /
hex** over the raw body (binary `data`) with the App Secret credential. The result
must equal the `X-Hub-Signature-256` header Meta sent, minus its `sha256=` prefix.
If it doesn't, the request didn't come from Meta (or the secret is wrong) and we
drop it.

### Loop Over Items — we name it `LOOP …`

*Node picker → **Loop Over Items** (older name: Split in Batches).* Takes a list
and feeds it to the following nodes **one item at a time** (*Batch Size: 1*). It
has two outputs: **loop** (the current item: connect your per-message work here)
and **done** (fires after the last item: leave it unconnected). **Every branch
inside the loop must end by connecting back into the LOOP node's input.** A branch
that just stops ends the whole loop early, and the remaining messages in that batch
are silently skipped.

### Two webhooks on one path

Meta uses **GET** for the handshake and **POST** for messages, on the **same URL**.
n8n allows two Webhook nodes with the same path as long as their HTTP methods
differ.

---

## G5. Build WF-09 — Outbound Router

New workflow: **`SF WF-09 Outbound Router`**. Tags: `salesfixr`, `channel`.

### Node 1 — `TRG Called By Workflow`

Input data mode: **Define using fields below**. All **String**: `correlation_id`,
`tenant_slug`, `channel`, `address`, `text`.

`address` means "where to send on that channel": a Messenger PSID, later a phone
number.

### Node 2 — `SW Route By Channel`  (Switch)

Value `{{ $json.channel }}`, rules **is equal to** `messenger` → output
`messenger`, `test` → output `test`. Fallback Output: **Extra Output**, renamed
`unsupported`.

### Node 3 — `HTTP Send Messenger Reply`  (HTTP Request)  ← `messenger`

| Setting | Value |
|---|---|
| Method | `POST` |
| URL | `https://graph.facebook.com/{{ $env.SF_META_GRAPH_VERSION }}/me/messages` |
| Authentication | **Generic Credential Type → Query Auth** → `SalesFixr Meta Page Token` |
| Send Body | JSON, Using JSON |
| JSON | `{{ JSON.stringify({ recipient: { id: $json.address }, messaging_type: 'RESPONSE', message: { text: String($json.text || '').slice(0, 2000) } }) }}` |
| Options → Timeout | `15000` |
| Options → Response → Never Error | **on** |

**Settings:** On Error → **Continue**. **No** Retry On Fail: if Meta received the
message but the response got lost, a retry would send the patient the same text
twice.

- `messaging_type: RESPONSE` = "replying to a message the person sent us". It's
  allowed for 24 hours after their last message. (Reminders in H are *not*
  responses; H deals with that.)
- Messenger caps a text message at 2000 characters, hence the `slice`.

### Node 4 — `FN Test Channel Noop`  (Code)  ← `test`

```javascript
// The test channel's reply already went back in the HTTP response (WF-01 → RESP Ack).
return [{ json: { skipped: true } }];
```

### Node 5 — `FN Unsupported Channel`  (Code)  ← `unsupported`

```javascript
return [{ json: { unsupported: true } }];
```

### Node 6 — `FN Send Result`  (Code)

Three inputs: nodes 3, 4 and 5.

```javascript
// One normalised answer, whatever channel ran.
const req = $('TRG Called By Workflow').first().json;
const ran = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };

let ok = false, reason, provider_message_id = null, error = null;
if (ran('HTTP Send Messenger Reply')) {
  const r = $('HTTP Send Messenger Reply').first().json;
  if (r.message_id) {
    ok = true; reason = 'ok'; provider_message_id = r.message_id;
  } else {
    reason = 'send_failed';
    error = r.error?.message || (typeof r.error === 'string' ? r.error : JSON.stringify(r).slice(0, 300));
  }
} else if (ran('FN Test Channel Noop')) {
  ok = true; reason = 'ok';
} else {
  reason = 'channel_unsupported';
}

return [{ json: { ok, reason_code: reason, provider_message_id, error,
                  correlation_id: req.correlation_id, tenant_slug: req.tenant_slug, channel: req.channel } }];
```

### Node 7 — `PG Log Outbound`  (Postgres)

```sql
INSERT INTO audit_logs (tenant_id, workflow, action, status, reason_code, correlation_id, details)
SELECT (SELECT id FROM tenants WHERE slug = $1), 'WF-09', 'send', $2, $3, $4, $5::jsonb
RETURNING id;
```

**Query Parameters:**

```
{{ [ $json.tenant_slug, ($json.ok ? 'ok' : 'error'), $json.reason_code, $json.correlation_id, JSON.stringify({ channel: $json.channel, provider_message_id: $json.provider_message_id, error: $json.error }) ] }}
```

### Node 8 — `FN Return Send Result`  (Code)

```javascript
return [{ json: $('FN Send Result').first().json }];
```

**Save → Publish.**

> **About the outbound `conversations` row:** WF-02 already saves the reply it
> produced as an outbound row (Milestone C). That stays the record of *what we
> said*. WF-09's audit row is the record of *whether it was delivered*. Two facts,
> two places.

---

## G6. Build WF-11 — Messenger Channel

New workflow: **`SF WF-11 Messenger Channel`**. Tags: `salesfixr`, `channel`.

### Part 1: the handshake (GET)

**Node 1 — `WH Messenger Verify`**  (Webhook)

| Setting | Value |
|---|---|
| HTTP Method | `GET` |
| Path | `salesfixr/v1/inbound/messenger` |
| Respond | Using 'Respond to Webhook' Node |

**Node 2 — `IF Verify Token Matches`**  (If)

`{{ $json.query['hub.mode'] === 'subscribe' && $json.query['hub.verify_token'] === $env.SF_META_VERIFY_TOKEN }}`
**Boolean → is true**.

**Node 3 — `RESP Challenge`**  (Respond to Webhook)  ← true

| Setting | Value |
|---|---|
| Respond With | **Text** |
| Response Body | `{{ $json.query['hub.challenge'] }}` |

**Node 4 — `RESP Forbidden`**  (Respond to Webhook)  ← false

Respond With **Text**, body `forbidden`, Options → Response Code `403`.

Meta sends this GET once, when you register the webhook in G8. It's checking you
own this URL: you prove it by echoing `hub.challenge`, but only if the verify token
matches the secret string you chose.

### Part 2: messages (POST)

**Node 5 — `WH Messenger Events`**  (Webhook)

| Setting | Value |
|---|---|
| HTTP Method | `POST` |
| Path | `salesfixr/v1/inbound/messenger` (same as node 1) |
| Respond | **Immediately** |
| Options → Response Code | `200` |
| Options → **Raw Body** | **on** |

No Authentication here: Meta can't send your custom header. The signature check
in nodes 6–7 is the authentication.

**Node 6 — `CRY Sign Raw Body`**  (Crypto)

| Setting | Value |
|---|---|
| Action | **Hmac** |
| Binary File | **on**, Binary Property `data` |
| Type | **SHA256** |
| Credential (Hmac Secret) | `SalesFixr Meta App Secret` |
| Property Name | `computed_signature` |
| Encoding | **HEX** |

**Node 7 — `FN Verify And Split Events`**  (Code, Run Once for All Items)

```javascript
// FN Verify And Split Events
// 1. Reject anything Meta didn't sign with OUR app secret.
// 2. Turn Meta's batch into one item per real text message.

const item = $input.first().json;
const header = String((item.headers || {})['x-hub-signature-256'] || '');   // n8n lowercases header names
const expected = 'sha256=' + String(item.computed_signature || '');

if (!header || header !== expected) {
  return [{ json: { kind: 'rejected', reason: 'bad_signature', had_header: !!header } }];
}

const body = item.body || {};
if (body.object !== 'page') return [];                 // not a Page event, nothing to do

const out = [];
for (const entry of body.entry || []) {
  for (const ev of entry.messaging || []) {
    const m = ev.message;
    if (!m || m.is_echo) continue;                     // our own outgoing messages come back as echoes
    const text = String(m.text || '').trim();
    if (!text) continue;                               // stickers, photos, voice notes: ignored in the MVP
    out.push({ json: {
      kind: 'message',
      page_id: String(entry.id),
      psid: String(ev.sender && ev.sender.id),
      mid: String(m.mid),
      text: text.slice(0, 2000),
      ts: ev.timestamp,
    } });
  }
}
return out;                                            // [] for delivery/read receipts etc.
```

- **Echoes:** when the Page sends a message (our reply), Meta reports it back as an
  event with `is_echo: true`. Without skipping those, the bot would answer itself
  forever.
- **Delivery/read receipts** have no `message` and are skipped. Returning `[]`
  simply ends the run: there's nothing to do.

**Node 8 — `IF Is Message`**  (If)

`{{ $json.kind }}` **String → is equal to** `message`. **true** → node 10.
**false** → node 9.

**Node 9 — `PG Log Rejected Webhook`**  (Postgres)

```sql
INSERT INTO audit_logs (workflow, action, status, reason_code, details)
VALUES ('WF-11', 'messenger_webhook', 'blocked', $1, $2::jsonb)
RETURNING id;
```

Parameters: `{{ [ $json.reason, JSON.stringify({ had_header: $json.had_header }) ] }}`

Forged or misconfigured requests leave a trace. If *every* real message lands here,
your App Secret credential is wrong.

**Node 10 — `LOOP Each Message`**  (Loop Over Items)

Batch Size **1**. Connect the **loop** output → node 11. Leave **done**
unconnected.

**Node 11 — `PG Claim Event`**  (Postgres)

Idempotency, master plan rule 4: Meta retries deliveries, and each message id
(`mid`) must be processed **once**.

```sql
WITH page AS (
  SELECT t.id, t.slug
  FROM clinic_settings s JOIN tenants t ON t.id = s.tenant_id
  WHERE s.messenger_page_id = $1 AND t.is_active
),
claim AS (
  INSERT INTO processed_events (tenant_id, channel, event_key)
  SELECT id, 'messenger', $2 FROM page
  ON CONFLICT (channel, event_key) DO NOTHING
  RETURNING id
)
SELECT (SELECT slug FROM page)     AS tenant_slug,
       EXISTS (SELECT 1 FROM claim) AS is_new,
       EXISTS (SELECT 1 FROM page)  AS page_known;
```

Parameters: `{{ [ $json.page_id, $json.mid ] }}`

**Node 12 — `IF New Event`**  (If)

`{{ $json.is_new }}` **Boolean → is true**. **true** → node 13. **false** →
**back to `LOOP Each Message`** (duplicate, or a Page no clinic owns).

**Node 13 — `HTTP Call WF-01`**  (HTTP Request)

| Setting | Value |
|---|---|
| Method | `POST` |
| URL | `http://localhost:5678/webhook/salesfixr/v1/inbound/normalized` |
| Authentication | **Generic Credential Type → Header Auth** → `SalesFixr Internal` |
| Send Body | JSON, Using JSON |
| JSON | see below |
| Options → Timeout | `90000` |
| Options → Response → Never Error | on |

**Settings:** On Error → **Continue**.

JSON:

```
{{ JSON.stringify({ tenant_slug: $json.tenant_slug, channel: 'messenger', external_contact_id: $('LOOP Each Message').item.json.psid, external_message_id: $('LOOP Each Message').item.json.mid, message: $('LOOP Each Message').item.json.text }) }}
```

This is exactly the envelope `FN Normalize Inbound` has understood since Milestone A
(`external_contact_id`, `external_message_id`). Messenger needed **no change** to
the brain.

**Node 14 — `IF Has Reply`**  (If)

`{{ typeof $json.reply_text === 'string' && $json.reply_text.length > 0 }}`
**Boolean → is true**. **true** → node 15. **false** → **back to `LOOP Each
Message`** (blocked by the gate: opted out, paused or rate-limited, so we stay
silent on purpose).

**Node 15 — `SUB Call WF-09 Send`**  (Execute Workflow)

Workflow: **SF WF-09 Outbound Router**. Inputs:

| Field | Expression |
|---|---|
| `correlation_id` | `{{ $json.correlation_id }}` |
| `tenant_slug` | `{{ $('PG Claim Event').item.json.tenant_slug }}` |
| `channel` | `messenger` |
| `address` | `{{ $('LOOP Each Message').item.json.psid }}` |
| `text` | `{{ $json.reply_text }}` |

**Settings:** On Error → **Continue**. Connect its output **back to `LOOP Each
Message`**.

### Check the loop wiring

Three lines must enter `LOOP Each Message` from below: from `IF New Event` (false),
`IF Has Reply` (false) and `SUB Call WF-09 Send`. Plus the original one from `IF Is
Message` (true). If any branch ends without returning to the loop, a batch of two
messages answers only the first.

**Save → Publish.**

---

## G7. WF-01: the internal entrance

Open **SF WF-01 Inbound Gateway**. Add a Webhook node:

**`WH Inbound Normalized`**

| Setting | Value |
|---|---|
| HTTP Method | `POST` |
| Path | `salesfixr/v1/inbound/normalized` |
| Authentication | **Header Auth** → `SalesFixr Internal` |
| Respond | Using 'Respond to Webhook' Node |

Connect it to **`FN Normalize Inbound`**: the same node `WH-Inbound-Test` feeds. One
gateway, two doors, both locked. `RESP Ack` answers whichever door the request
came through.

**Save → Publish.**

> Why not let WF-11 use `/inbound/test`? It would work, but every audit row and
> every future reader would see Facebook traffic arriving through a door called
> "test". Names are documentation. `normalized` says what it is: any adapter that
> has already converted its channel's payload into the standard envelope.

---

## G8. Register the webhook with Meta  (doc 01 §7, step 7)

1. ngrok running (G2). WF-11 **Published**.
2. Meta app → **Messenger → Settings → Webhooks → Add Callback URL**:
   - Callback URL: `https://your-domain.ngrok-free.app/webhook/salesfixr/v1/inbound/messenger`
   - Verify Token: your `SF_META_VERIFY_TOKEN`
   - **Verify and save.** Meta calls the GET from G6 Part 1. In n8n, WF-11's
     executions show one run ending at `RESP Challenge`.
3. **Subscribe your Page** to the webhook fields `messages` and
   `messaging_postbacks` (the *Add subscriptions* button next to the Page in the
   same section).

If verification fails, see the troubleshooting table. The usual cause is that
WF-11 isn't published, or the verify token in Meta and `.env` differ by one
character.

---

## G9. First message, and making yourself the owner

### G9.1 As a patient

From your phone, open your Page in Messenger and send: **"Hi, are you open on
Saturday?"**

Within ~10 seconds you should get the hours. In n8n → Overview → Executions you'll
see three runs: WF-11 (Messenger), WF-01, WF-02, plus WF-10 and WF-09.

Right now **you are a patient** to the system: there's no `staff_users` row for
your Messenger identity. Good, because that lets you test the patient side first.
Do the booking now (G10 steps 1–3), *then* promote yourself.

### G9.2 Promote yourself to owner

Your Messenger id (PSID) was stored when your first message arrived:

```sql
SELECT ci.external_contact_id AS psid, ci.created_at, c.id AS contact_id
FROM contact_identities ci JOIN contacts c ON c.id = ci.contact_id
WHERE ci.channel = 'messenger'
ORDER BY ci.created_at;
```

If you're the only person who has messaged the Page, there's one row. That's you.

```sql
INSERT INTO staff_users (tenant_id, full_name, role, channel, external_contact_id)
SELECT id, 'Owner (Messenger)', 'owner', 'messenger', 'PASTE-YOUR-PSID'
FROM tenants WHERE slug = 'demo_clinic'
ON CONFLICT DO NOTHING;
```

That single row is the entire difference between "patient" and "owner". Nothing
you *say* in a message can change it (doc 03, layer 1).

**Want to keep testing as a patient too?** Add a second Facebook account as a
**Tester** (Meta app → App roles → Roles → Add Testers; the other account must
accept the invite at developers.facebook.com). Messages from that account are a
patient's.

---

## G10. Acceptance tests from your phone

Use a weekday 1–6 days ahead (`Monday` below). Do 1–3 **before** G9.2, while
you're still a patient.

| # | You send (Messenger) | Expect |
|---|---|---|
| 1 | "Can I book a cleaning on Monday at 10am?" | Real availability. Free → "Would you like me to book it?"; taken → three nearby times |
| 2 | "Yes please, my name is *your name*" | "You're booked: Dental Cleaning on Monday … at 10:00 AM. See you then!" **+ Telegram ping + calendar event** |
| 3 | "Can I book a cleaning on Monday at 10am?" (again) | 10:00 now taken → alternatives. Your own booking blocks it too |
| — | *Do G9.2 now: promote yourself to owner* | |
| 4 | "What does Monday look like?" | **Owner answer**: "Monday …: 1 appointment" with your booking, name and phone. **Master-plan step 6** |
| 5 | "STOP" | As an owner the opt-out is still honoured: "You have been unsubscribed…". Send "START" to undo |
| 6 | A photo or sticker | No reply (MVP ignores non-text). Nothing breaks |

**Signature and duplicate tests (PowerShell).** These prove the two security
properties you can't test from the phone: forged events are rejected, and Meta's
retries don't produce double replies.

```powershell
cd F:\Agency\Automation_MVP
. .\tests\sf-helpers.ps1
$psid = "PASTE-YOUR-PSID"
$mid  = "m_test_" + (Get-Random)
Send-MessengerEvent $psid $mid "What are your opening hours?"      # correctly signed
Send-MessengerEvent $psid $mid "What are your opening hours?"      # exact retry, same mid
Send-MessengerEvent $psid ("m_test_" + (Get-Random)) "hi" -BadSignature
```

`Send-MessengerEvent` (in the helpers) builds a Messenger payload, signs it with
your App Secret from `.env` exactly as Meta does, and posts it to
`http://localhost:5678/webhook/salesfixr/v1/inbound/messenger`.

| Check | Expect |
|---|---|
| Your phone | **One** reply with the hours, not two |
| Executions | Second WF-11 run stops at `IF New Event` (false). No WF-01 run for it |
| Audit | The forged one is logged: |

```sql
SELECT created_at, workflow, reason_code FROM audit_logs
WHERE workflow IN ('WF-11', 'WF-09') ORDER BY id DESC LIMIT 10;
```

You should see `WF-11 … bad_signature` once, and `WF-09 send ok` rows for the real
replies.

**Clean up** the test booking (SQL from F8 + delete the calendar event).

---

## G11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Meta: "The URL couldn't be validated" | WF-11 not **Published**; ngrok not running; or verify token mismatch. Check WF-11's executions: no run means Meta can't reach you; a run ending in `RESP Forbidden` means the token differs |
| Meta says verified, but messages produce no WF-11 run | Page not subscribed to `messages` (G8 step 3), or you're messaging from an account with no app role (Development mode) |
| Every message ends at `PG Log Rejected Webhook`, `bad_signature` | Wrong App Secret in the *Crypto* credential, or Raw Body is off (the HMAC is then computed over the wrong bytes) |
| WF-11 runs, `IF New Event` always false | `clinic_settings.messenger_page_id` not set or wrong. `page_known` in `PG Claim Event`'s output tells you |
| WF-01 run happens but no reply on the phone | Look at WF-09's run: `send_failed` with the Graph error. Most common: token expired or for a different Page, wrong `SF_META_GRAPH_VERSION`, or the reply was more than 24 h after the person's last message |
| `HTTP Call WF-01` returns 403 | `WH Inbound Normalized` and `HTTP Call WF-01` aren't using the same `SalesFixr Internal` credential |
| Bot replies to its own messages in a loop | The `is_echo` skip is missing in `FN Verify And Split Events`. Fix immediately: Meta can rate-limit or disable an app that loops |
| Two messages sent quickly, only the first answered | A branch inside the loop doesn't return to `LOOP Each Message` (G6 wiring check) |
| You still get patient answers after G9.2 | Wrong PSID in `staff_users`, or `channel` isn't `messenger`. Also check `is_active` |
| Replies take > 20 s and Meta retries | WF-11 must use **Respond: Immediately**. If it waits for the brain, Meta times out and retries; idempotency saves you from double answers, but fix the setting |
| Your PowerShell tests now get 403 | Expected after G1. Load `tests\sf-helpers.ps1`; check `SF_INTERNAL_TOKEN` is in `.env` and matches the credential |

---

## Done when

- [ ] G1: internal token credential; `WH-Inbound-Test` protected; unauthenticated call → 403; n8n 2FA on
- [ ] ngrok static domain running; `SF_PUBLIC_BASE_URL` set; `WEBHOOK_URL` unchanged
- [ ] Meta app, Page token, App Secret; `.env` values; Graph version current; `messenger_page_id` set
- [ ] WF-09 and WF-11 built and **Published**; WF-01 has `WH Inbound Normalized`, **Published**
- [ ] Meta webhook **verified**, Page subscribed to `messages`
- [ ] G10 phone tests 1–6 pass, **including the booking with Telegram ping** and the **owner schedule**
- [ ] Duplicate event → one reply; forged event → `bad_signature` audit row
- [ ] All workflows exported and committed:

```powershell
cd F:\Agency\Automation_MVP
git add docs workflows tests
git commit -m "Milestone G: Messenger channel (signature check, idempotency, outbound router)"
git push
```

**Next:** Milestone H — reminders: WF-04 drains the `reminders` table on a schedule,
through the safety gate's outbound rules (where quiet hours finally apply).
`docs/12-MILESTONE-H.md`.
