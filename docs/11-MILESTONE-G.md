# Milestone G — Real Messenger + Instagram Channel

**Goal:** pick up your phone, message the Facebook Page **or DM its Instagram
account**, and get the same behaviour you've been testing with PowerShell: real availability, a real booking,
a Telegram ping, an owner-style answer when *you* ask. The master-plan demo, for
real.

**Why now:** everything behind the front door is finished and tested. A, B and
C–F were deliberately built on the `test` channel, so every problem so far was a
logic problem, never a Facebook problem. G adds only the channel. If something
breaks now, it's in the new pieces, and the audit log tells you which.

**Time:** about 3 hours, plus the time the Page owner needs for
`docs/META-ACCESS-HANDOFF.md` (about 30 minutes on their side). You never log in to
Facebook for this milestone.

**Prerequisite:** Milestone F green: the F8 demo passes on the test channel.

**New to Meta's developer tools?** That's expected. G2, G3 and G8 are written
step by step, and the Meta parts run from PowerShell scripts. Every step ends with a **Check** so you know it worked before
moving on. Do the sections in order: G1 → G2 → G3 → G4 (read) → G5 → G6 → G7 →
G8 → G9 → G10.

**Acceptance test (master plan):** message the Page from a phone, get a real
reply; DM the Instagram account, get a real reply. Then run master-plan steps 1–7 from the phone.

---

## G0. What gets built

```
Phone (Messenger or Instagram) ──► Meta servers ──► https://<you>.ngrok-free.app ──► n8n on your PC
                                                    │
     ┌──────────────────────────────────────────────┘
     ▼
SF WF-11 Messenger Channel                                   (new: the Messenger adapter)
  GET  /inbound/messenger → verify token  → echo challenge          (one-time handshake)
  POST /inbound/messenger → answer 200 immediately     (Messenger AND Instagram events)
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

## G2. ngrok: the public address

Facebook's servers can't reach `localhost`. ngrok gives your PC a fixed public
`https://` address that forwards to n8n. Do this once.

### G2.1 Account and domain (browser, ~5 min)

1. Go to **https://ngrok.com** → **Sign up** (Google sign-in is fine). No card is asked.
2. You land on the **ngrok dashboard**. In the left menu:
   - **Getting Started → Your Authtoken** → click **Copy**. Keep this tab open.
   - **Universal Gateway → Domains** (older layout: **Cloud Edge → Domains**).
     The free plan gives you **one** domain, already created for you, ending in
     `.ngrok-free.app` or `.ngrok-free.dev`. If the list is empty, click
     **+ New Domain** → **Create**. Copy the domain, e.g.
     `honest-koala-12ab.ngrok-free.dev`. It never changes, which is why Meta can
     keep using it.

### G2.2 Install and connect (PowerShell, ~3 min)

```powershell
winget install ngrok.ngrok        # if winget isn't available: download from ngrok.com/download, unzip ngrok.exe into C:\ngrok and run it from there
ngrok version                     # close and reopen PowerShell if "ngrok" isn't recognised
ngrok config add-authtoken PASTE-THE-AUTHTOKEN
```

Expect: `Authtoken saved to configuration file`.

### G2.3 Save the address in `.env`

```powershell
notepad F:\Agency\Automation_MVP\infra\.env
```

Find (or add) the line and set it to **your** domain, `https://`, no slash at the end:

```
SF_PUBLIC_BASE_URL=https://honest-koala-12ab.ngrok-free.dev
```

Save, close Notepad.

**Leave `WEBHOOK_URL=http://localhost:5678` as it is.** It only controls the URLs
n8n *displays* and the Google OAuth redirect address. Webhooks are reachable
through the tunnel either way. Changing it would change your Google Calendar
redirect URL and force you to redo E1.2.

### G2.4 Start the tunnel

Open a **new** PowerShell window just for ngrok and keep it open while you test:

```powershell
ngrok http 5678 --url=https://honest-koala-12ab.ngrok-free.dev
```

You'll see a status screen with `Session Status  online` and a `Forwarding` line
pointing to `http://localhost:5678`. Closing this window = Facebook can't reach you.

**Check:** open your domain in a browser. ngrok's free plan first shows a page
saying *"You are about to visit…"* → click **Visit Site** → the n8n sign-in page
appears. That warning page is only for browsers; Meta's servers never see it.

---

## G3. Meta access: Page + Instagram, without logging in to Facebook

**You never log in to anyone's Facebook or Instagram, and you don't need to log in
to your own Facebook on your laptop for this milestone.** The owner of the Page
creates a **System User** token in their Business Manager and sends it to you.
A System User is a non-human account: no password, no login, a token that
**never expires**, and the owner can revoke it in one click. It's the method Meta
documents for agencies and automation. Everything after that (checks, Page token,
webhook registration) you do from PowerShell in G3.4 and G8.

### G3.1 Which route?

| Situation | Who does what | Doc to send them |
|---|---|---|
| **Portfolio / demo** (your friend's dummy Page + Instagram) | Friend creates the app + System User and sends you **4 values** | `docs/META-ACCESS-HANDOFF.md`, **Part A** |
| **Paying client** (later) | Client adds **your agency's Business Manager** as a partner. You create the token on your side (G3.7) | `docs/META-ACCESS-HANDOFF.md`, **Part B** |

For now: send your friend `docs/META-ACCESS-HANDOFF.md` and ask for **Part A**. It
starts with 4 checks that save hours of confusing errors:

1. Instagram is a **Business or Creator** account (personal accounts have no API).
2. Instagram is **linked to the Facebook Page** (the API reaches Instagram through the Page).
3. Page and Instagram are **inside their Business portfolio** (the System User can only see assets in it).
4. Instagram → Messages → Connected tools → **Allow access to messages** is ON.

You'll receive: **App ID**, **App secret**, **System user token**, **Page ID**.

> **What you should never receive or ask for:** a password, a login code, or cookies.
> If a client offers their password "to make it easier", say no. It's both a security
> risk and against Meta's terms, and a token is easier anyway.

### G3.2 Put them in `.env`

```powershell
notepad F:\Agency\Automation_MVP\infra\.env
```

Add or fill these lines (one value per line, no spaces, no quotes):

```
SF_META_APP_ID=the-app-id
SF_META_APP_SECRET=the-app-secret
SF_META_SYSTEM_USER_TOKEN=the-system-user-token
SF_META_PAGE_ID=the-page-id
SF_META_GRAPH_VERSION=v26.0
SF_META_VERIFY_TOKEN=
```

**Verify token:** invent one (you'll use it in G8):

```powershell
"sf_verify_" + (-join ((97..122)+(48..57) | Get-Random -Count 16 | % {[char]$_}))
```

Paste the result after `SF_META_VERIFY_TOKEN=`. **Save**, close Notepad.

> `SF_META_PAGE_TOKEN` and `SF_META_IG_ACCOUNT_ID` are filled in **automatically** by
> the next step. Don't type them.

### G3.3 Migration 006 (Instagram)

Neon → SQL Editor → paste and **Run** `db/006_instagram_channel.sql`:

```sql
-- =====================================================================
-- 006 — Instagram DMs (Milestone G)
--
-- Messenger events name the Facebook PAGE they're for; Instagram events
-- name the INSTAGRAM professional account. WF-11 looks up which clinic
-- owns the account an event arrived on, so the clinic needs both ids.
--
-- Safe to re-run.
-- =====================================================================

ALTER TABLE clinic_settings
  ADD COLUMN IF NOT EXISTS instagram_account_id text;

CREATE UNIQUE INDEX IF NOT EXISTS clinic_settings_instagram_uq
  ON clinic_settings (instagram_account_id) WHERE instagram_account_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS clinic_settings_messenger_page_uq
  ON clinic_settings (messenger_page_id) WHERE messenger_page_id IS NOT NULL;

COMMENT ON COLUMN clinic_settings.instagram_account_id IS
  'Instagram professional account id (entry.id in Instagram webhook events). '
  'Set from tests\meta-setup.ps1 Test-MetaAccess output.';
```

### G3.4 Check the access, before n8n is involved at all

This proves the credentials work *on their own*, so a credential problem can never be
confused with a workflow problem later.

```powershell
cd F:\Agency\Automation_MVP
. .\tests\meta-setup.ps1           # dot, space, path
Test-MetaAccess
```

Expected (names are your friend's):

```
1. The token itself
  [OK]   Token is valid
  [OK]   Token belongs to this app (1234567890)
  [OK]   Token type is SYSTEM_USER (is: SYSTEM_USER)
  [OK]   Token never expires
  [OK]   Scopes present
2. The Facebook Page
  [OK]   Page: Dummy Dental (1029384756)
  [OK]   Page access token issued (needed to send messages)
         saved to infra\.env as SF_META_PAGE_TOKEN (not shown)
3. The Instagram account
  [OK]   Instagram: @dummydental (17841400000000000)
         saved to infra\.env as SF_META_IG_ACCOUNT_ID
4. Paste into the Neon SQL editor:
   UPDATE clinic_settings SET messenger_page_id = '…', instagram_account_id = '…' …
```

**Run the SQL from step 4** in Neon. Expect one row back with both ids.

| A line says `[FAIL]` | What it means → who fixes it |
|---|---|
| "Meta rejected the App ID / App Secret / token" | One of the three was copied wrong (often a missing character at the end). Re-copy from the friend's message |
| "Token belongs to this app" fails | The token was generated for a different app. Friend: Part A2 step 3, select `SalesFixr Demo` |
| "Token type is SYSTEM_USER" fails (says `USER`) | Friend sent a personal token (e.g. from Graph API Explorer). It expires in hours. Ask for a System User token (Part A2) |
| "Token never expires" fails | Friend chose an expiry. Regenerate with **Never** |
| "Scopes present - missing: …" | Friend didn't tick those permissions. Regenerate the token with all 7 (Part A2 step 3). Missing `instagram_*` scopes also means they weren't added to the app (Part A1 step 5) |
| "Page … not readable with this token" | The Page isn't assigned to the System User, or the Page ID is wrong. Friend: Part A2 step 2 |
| "No Instagram professional account is linked" | Checks 1–2 failed. Messenger still works; Instagram won't until it's fixed |

### G3.5 Two n8n credentials

**Tokens live only in n8n's credential store.** Never paste a token into a node
field, an HTTP header field or a Code node: those are saved in execution logs and in
exported workflow JSON (which you commit to git).

n8n → **Overview** → **Create** (arrow) → **Credential**.

**Page token** (used to *send* replies on Messenger **and** Instagram): search
**Query Auth**.

| Field | Mode | Value |
|---|---|---|
| Credential name (click the title) | — | `SalesFixr Meta Page Token` |
| Name | Fixed | `access_token` |
| Value | Fixed | the `SF_META_PAGE_TOKEN` line from `.env` (Notepad → copy everything after the `=`) |

**App secret** (used to *verify* that incoming events really come from Meta): search
**Crypto**.

| Field | Mode | Value |
|---|---|---|
| Credential name | — | `SalesFixr Meta App Secret` |
| Hmac Secret | Fixed | the App secret |
| (other fields, if shown) | — | leave empty |

Then load the two non-secret Meta values into n8n (verify token and API version):

```powershell
cd F:\Agency\Automation_MVP\infra
docker compose up -d
```

> **Why the Page token, not the System User token, goes into n8n:** Meta's Send API
> requires a *Page* token. `Test-MetaAccess` derived it from the System User token.
> Because the System User's token never expires, neither does this Page token. If the
> owner revokes the System User, both stop working, which is exactly what revoking
> should do.

### G3.6 Who can talk to the bot (Development mode)

The app stays in **Development** mode for the portfolio. Then Meta forwards messages
**only** from people with a role on the app (admins, developers, testers), plus admins
of the Page. Everyone else's messages still reach the Page/Instagram inbox, but the
bot never sees them. That's right for building and demos.

- **Easiest:** your friend sends the test messages from his dummy accounts (he's admin).
- **Test from your own phone:** your friend adds you as **Tester** (your Facebook) and
  **Instagram Tester** (your Instagram), Part A3. You accept once **on your phone**:
  - Facebook: you must be a registered developer first (developers.facebook.com →
    **Get Started**, verify phone). Then, in the phone browser with **Desktop site** on,
    tap your **profile icon** (top right) on developers.facebook.com: the pending
    invite is there → **Accept**. No email is sent. Until you accept, the owner sees
    you as *Pending* and Meta forwards none of your messages.
  - Instagram: Instagram → Settings → **Apps and websites** → **Tester invites** →
    Accept (if the app doesn't show it, open instagram.com in the phone browser).

### G3.7 Later, for clients: your agency's own setup (one time)

Not needed for the portfolio. When the first client comes, you need **one** login
(your own real Facebook, and a phone browser is fine) to create:

1. Your agency **Business portfolio** at business.facebook.com. Note the **Business
   ID** (Settings → Business info). That's what clients paste in Part B.
2. Your agency **developer app** (same steps as Part A1, under your business).
3. Your own **System User** (`n8n-automation`, Admin), with your app assigned.

For each client: they do Part B (partner access). Their Page and Instagram appear in
your Business settings → assign them to your System User (Full control) → **Generate
token** for your app → it goes into `.env` exactly like G3.2, and every later step is
identical.

**Real patients need the app Live.** Moving to Live requires Meta **App Review** of
the messaging permissions (a screen recording of the bot in use and a public privacy
policy URL; brandfixr.com can host it) and **Business Verification** of your agency
business. Expect days to weeks: start it as soon as a client signs, not on launch day.

**Account safety (your own agency account):** authenticator-app 2FA (not SMS); check
Facebook → Settings → Security → **Where you're logged in** now and then; keep Chrome
extensions to the ones you trust. Stolen browser sessions via bad extensions are how
agency accounts usually get compromised. Unofficial automation (bots clicking
facebook.com) is what gets accounts banned. Everything in this project uses the
official Graph API only.

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

### One URL for Messenger and Instagram

Instagram DMs to an account linked to the Page use the **same Messenger Platform**:
same webhook URL, same signature, same payload shape, same Send API and Page token.
The only differences: the event says `"object": "instagram"` instead of `"page"`,
`entry.id` is the **Instagram account id** instead of the Page id, the sender id is
an **IGSID** instead of a PSID, and Instagram texts are capped at **1000** characters
(Messenger: 2000). So WF-11 and WF-09 handle both with a `channel` field, and WF-01 to
WF-10 don't change at all (`instagram` has been in the `channel_t` enum since
Milestone A).

### Two webhooks on one path

Meta uses **GET** for the handshake and **POST** for messages, on the **same URL**.
n8n allows two Webhook nodes with the same path as long as their HTTP methods
differ.

---

## G5. Build WF-09 — Outbound Router

New workflow: **`SF WF-09 Outbound Router`**. Tags: `salesfixr`, `channel`.

### Node 1 — `TRG Called By Workflow`

Input data mode: **Define using fields below**. All **String**: `correlation_id`,
`tenant_slug`, `channel`, `address`, `text`, `messaging_type`.

`address` means "where to send on that channel": a Messenger PSID, later a phone
number. `messaging_type` is `RESPONSE` for a reply to the patient's message (WF-11)
and `UPDATE` for a message we start ourselves (Milestone H reminders). Empty means
`RESPONSE`.

### Node 2 — `SW Route By Channel`  (Switch)

Mode **Rules**. Three rules; in each, the left box is the **Expression**
`{{ $json.channel }}`, operator **String → is equal to**, right box **Fixed**:

| Rule | Right value | Rename Output → output name |
|---|---|---|
| 1 | `messenger` | `messenger` |
| 2 | `instagram` | `instagram` |
| 3 | `test` | `test` |

Options → **Fallback Output: Extra Output**, renamed `unsupported`.

### Node 3 — `HTTP Send Meta Reply`  (HTTP Request)  ← `messenger` **and** `instagram`

| Setting | Value |
|---|---|
| Method | `POST` |
| URL (**Expression**) | `https://graph.facebook.com/{{ $env.SF_META_GRAPH_VERSION }}/me/messages` |
| Authentication | **Generic Credential Type → Query Auth** → `SalesFixr Meta Page Token` |
| Send Body | JSON, Using JSON |
| JSON (**Expression**) | `{{ JSON.stringify({ recipient: { id: $json.address }, ...($json.channel === 'messenger' ? { messaging_type: $json.messaging_type || 'RESPONSE' } : {}), message: { text: String($json.text || '').slice(0, $json.channel === 'instagram' ? 1000 : 2000) } }) }}` |
| Options → Timeout | `15000` |
| Options → Response → Never Error | **on** |

**Settings:** On Error → **Continue**. **No** Retry On Fail: if Meta received the
message but the response got lost, a retry would send the patient the same text
twice.

- `messaging_type: RESPONSE` = "replying to a message the person sent us";
  `UPDATE` = "a message we start". Both are only allowed within **24 hours** of the
  person's last message to the Page. (Meta retired the old message tags that used
  to allow reminders outside that window in 2026. Milestone H handles that.)
- Messenger caps a text message at 2000 characters, Instagram at 1000, hence the
  `slice`. `messaging_type` is a Messenger field; Instagram doesn't use it.
- `/me/messages` with the **Page** token works for both: for an Instagram account
  linked to the Page, Meta delivers to the IGSID in `recipient.id`.

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
if (ran('HTTP Send Meta Reply')) {
  const r = $('HTTP Send Meta Reply').first().json;
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
                  correlation_id: req.correlation_id, tenant_slug: req.tenant_slug, channel: req.channel,
                  text: req.text } }];   // echoed so callers (H reminders) can log what was sent
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

### Wiring table — `SF WF-09 Outbound Router`

Draw exactly these connections, and nothing else. "→" means: drag from the **output** dot on the right of the first node to the **input** dot on the left of the second.

| # | From (output) | To (input) |
|---|---|---|
| 1 | `TRG Called By Workflow` | `SW Route By Channel` |
| 2 | `SW Route By Channel` output **messenger** | `HTTP Send Meta Reply` |
| 3 | `SW Route By Channel` output **instagram** | `HTTP Send Meta Reply` (the same node) |
| 4 | `SW Route By Channel` output **test** | `FN Test Channel Noop` |
| 5 | `SW Route By Channel` output **unsupported** | `FN Unsupported Channel` |
| 6 | `HTTP Send Meta Reply` | `FN Send Result` |
| 7 | `FN Test Channel Noop` | `FN Send Result` |
| 8 | `FN Unsupported Channel` | `FN Send Result` |
| 9 | `FN Send Result` | `PG Log Outbound` |
| 10 | `PG Log Outbound` | `FN Return Send Result` (last node) |

**Check:** `HTTP Send Meta Reply` has **2** incoming lines, `FN Send Result` has **3**. In `SW Route By Channel` the left box of all three rules is the Expression `{{ $json.channel }}` (green preview), not plain text.

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
| Response Body (**Expression**) | `{{ $json.query['hub.challenge'] }}` |

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
// Messenger ("object": "page") and Instagram ("object": "instagram") arrive on this
// same URL with the same shape; only the channel and the account id differ.

const item = $input.first().json;
const header = String((item.headers || {})['x-hub-signature-256'] || '');   // n8n lowercases header names
const expected = 'sha256=' + String(item.computed_signature || '');

if (!header || header !== expected) {
  return [{ json: { kind: 'rejected', reason: 'bad_signature', had_header: !!header } }];
}

const body = item.body || {};
const CHANNEL = { page: 'messenger', instagram: 'instagram' };
const channel = CHANNEL[body.object];
if (!channel) return [];                               // some other kind of event: nothing to do

const out = [];
for (const entry of body.entry || []) {
  for (const ev of entry.messaging || []) {
    const m = ev.message;
    if (!m || m.is_echo || m.is_deleted) continue;     // our own replies come back as echoes
    const text = String(m.text || '').trim();
    if (!text) continue;                               // stickers, photos, voice notes: ignored in the MVP
    out.push({ json: {
      kind: 'message',
      channel,                                         // 'messenger' | 'instagram'
      account_id: String(entry.id),                    // Page id (Messenger) or Instagram account id
      psid: String(ev.sender && ev.sender.id),         // the sender: PSID on Messenger, IGSID on Instagram
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
WITH acct AS (
  -- Which clinic owns the Page (Messenger) or Instagram account this event arrived on?
  SELECT t.id, t.slug
  FROM clinic_settings s JOIN tenants t ON t.id = s.tenant_id
  WHERE t.is_active
    AND (($3 = 'messenger' AND s.messenger_page_id = $1)
      OR ($3 = 'instagram' AND s.instagram_account_id = $1))
),
claim AS (
  INSERT INTO processed_events (tenant_id, channel, event_key)
  SELECT id, $3::channel_t, $2 FROM acct
  ON CONFLICT (channel, event_key) DO NOTHING
  RETURNING id
)
SELECT (SELECT slug FROM acct)      AS tenant_slug,
       EXISTS (SELECT 1 FROM claim) AS is_new,
       EXISTS (SELECT 1 FROM acct)  AS account_known;
```

Parameters (Expression): `{{ [ $json.account_id, $json.mid, $json.channel ] }}`

**Node 12 — `IF New Event`**  (If)

`{{ $json.is_new }}` **Boolean → is true**. **true** → node 13. **false** →
**back to `LOOP Each Message`** (duplicate, or a Page/Instagram account no clinic owns).

**Node 13 — `HTTP Call WF-01`**  (HTTP Request)

| Setting | Value |
|---|---|
| Method | `POST` |
| URL | `http://localhost:5678/webhook/salesfixr/v1/inbound/normalized` |
| Authentication | **Generic Credential Type → Header Auth** → `SalesFixr Internal` |
| Send Body | JSON, Using JSON |
| JSON (**Expression**) | see below |
| Options → Timeout | `90000` |
| Options → Response → Never Error | on |

**Settings:** On Error → **Continue**.

JSON:

```
{{ JSON.stringify({ tenant_slug: $json.tenant_slug, channel: $('LOOP Each Message').item.json.channel, external_contact_id: $('LOOP Each Message').item.json.psid, external_message_id: $('LOOP Each Message').item.json.mid, message: $('LOOP Each Message').item.json.text }) }}
```

This is exactly the envelope `FN Normalize Inbound` has understood since Milestone A
(`external_contact_id`, `external_message_id`). Messenger and Instagram needed **no
change** to the brain: an Instagram sender becomes a contact with an `instagram`
identity, a Messenger sender one with a `messenger` identity.

**Node 14 — `IF Has Reply`**  (If)

`{{ typeof $json.reply_text === 'string' && $json.reply_text.length > 0 }}`
**Boolean → is true**. **true** → node 15. **false** → **back to `LOOP Each
Message`** (blocked by the gate: opted out, paused or rate-limited, so we stay
silent on purpose).

**Node 15 — `SUB Call WF-09 Send`**  (Execute Workflow)

Workflow: **SF WF-09 Outbound Router**. Inputs:

| Field | Value (Expression unless marked Fixed) |
|---|---|
| `correlation_id` | `{{ $json.correlation_id }}` |
| `tenant_slug` | `{{ $('PG Claim Event').item.json.tenant_slug }}` |
| `channel` | `{{ $('LOOP Each Message').item.json.channel }}` |
| `address` | `{{ $('LOOP Each Message').item.json.psid }}` |
| `text` | `{{ $json.reply_text }}` |
| `messaging_type` | `RESPONSE` (Fixed) |

**Settings:** On Error → **Continue**. Connect its output **back to `LOOP Each
Message`**.

### Check the loop wiring

Three lines must enter `LOOP Each Message` from below: from `IF New Event` (false),
`IF Has Reply` (false) and `SUB Call WF-09 Send`. Plus the original one from `IF Is
Message` (true). If any branch ends without returning to the loop, a batch of two
messages answers only the first.

### Wiring table — `SF WF-11 Messenger Channel`

Draw exactly these connections, and nothing else. "→" means: drag from the **output** dot on the right of the first node to the **input** dot on the left of the second.

| # | From (output) | To (input) |
|---|---|---|
| 1 | `WH Messenger Verify` (GET) | `IF Verify Token Matches` |
| 2 | `IF Verify Token Matches` **true** | `RESP Challenge` (end) |
| 3 | `IF Verify Token Matches` **false** | `RESP Forbidden` (end) |
| 4 | `WH Messenger Events` (POST) | `CRY Sign Raw Body` |
| 5 | `CRY Sign Raw Body` | `FN Verify And Split Events` |
| 6 | `FN Verify And Split Events` | `IF Is Message` |
| 7 | `IF Is Message` **true** | `LOOP Each Message` (its input) |
| 8 | `IF Is Message` **false** | `PG Log Rejected Webhook` (end) |
| 9 | `LOOP Each Message` output **loop** | `PG Claim Event` |
| 10 | `LOOP Each Message` output **done** | nothing, leave it empty |
| 11 | `PG Claim Event` | `IF New Event` |
| 12 | `IF New Event` **true** | `HTTP Call WF-01` |
| 13 | `IF New Event` **false** | `LOOP Each Message` (back into its input) |
| 14 | `HTTP Call WF-01` | `IF Has Reply` |
| 15 | `IF Has Reply` **true** | `SUB Call WF-09 Send` |
| 16 | `IF Has Reply` **false** | `LOOP Each Message` (back into its input) |
| 17 | `SUB Call WF-09 Send` | `LOOP Each Message` (back into its input) |

**Check:** `LOOP Each Message`'s input has **4** incoming lines (rows 7, 13, 16, 17). The GET part and the POST part are two separate chains with no line between them.

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

Wiring: `WH Inbound Normalized` → **`FN Normalize Inbound`** (one new line; `WH-Inbound-Test` → `FN Normalize Inbound` stays). Connect it to **`FN Normalize Inbound`**: the same node `WH-Inbound-Test` feeds. One
gateway, two doors, both locked. `RESP Ack` answers whichever door the request
came through.

**Save → Publish.**

> Why not let WF-11 use `/inbound/test`? It would work, but every audit row and
> every future reader would see Facebook traffic arriving through a door called
> "test". Names are documentation. `normalized` says what it is: any adapter that
> has already converted its channel's payload into the standard envelope.

---

## G8. Register the webhook with Meta (from PowerShell)

Now Meta learns *where* to forward your Page's Messenger messages **and** your
Instagram DMs. Normally this is clicked in the app's dashboard, which belongs to the
app owner. With the App ID + App Secret you can do it through Meta's API instead, so
no one has to log in.

**Before you start, all three must be true:**

- The ngrok window from G2.4 is open and says `online`.
- **SF WF-11 Messenger Channel** is **Published**.
- You ran `docker compose up -d` after setting `SF_META_VERIFY_TOKEN` (G3.5).

```powershell
cd F:\Agency\Automation_MVP
. .\tests\meta-setup.ps1
Set-MetaWebhooks
```

Expected:

```
Callback URL: https://your-domain.ngrok-free.dev/webhook/salesfixr/v1/inbound/messenger
  [OK]   App webhook for 'page' messages
  [OK]   App webhook for 'instagram' messages
  [OK]   Page subscribed to the app (delivers Messenger + Instagram DMs)
```

What it did:

| Step | API call | Meaning |
|---|---|---|
| 1 | `POST /{app-id}/subscriptions` object `page` | "Send this app's **Messenger** events to my URL." Meta immediately calls your GET webhook with the verify token. |
| 2 | `POST /{app-id}/subscriptions` object `instagram` | Same for **Instagram** DMs, same URL |
| 3 | `POST /{page-id}/subscribed_apps` | Installs the app on the Page: "deliver this Page's messages to the app" |

**Check in n8n:** WF-11 → **Executions** → two new runs ending at `RESP Challenge`
(one per object). Then:

```powershell
Show-MetaWebhooks
```

shows `page` and `instagram`, both `active=True`, fields `messages,messaging_postbacks`,
and your app under the Page's subscribed apps.

**If your ngrok domain ever changes,** just run `Set-MetaWebhooks` again. It
overwrites the old URL.

### G8.1 If it fails

| What you see | Fix |
|---|---|
| `[FAIL] App webhook for 'page' … (2200) Callback verification failed` + a WF-11 run ending at `RESP Forbidden` | Verify tokens differ: `.env` vs what n8n loaded. Did you run `docker compose up -d` after editing `.env`? |
| Same error, **no** WF-11 run at all | Meta can't reach you: ngrok closed, wrong `SF_PUBLIC_BASE_URL`, or WF-11 not **Published** |
| Same error + a WF-11 run that errored | Open the run, the red node shows why. Usually `IF Verify Token Matches` typed in Fixed mode |
| `(100) … instagram … not supported` / permission error for `instagram` only | The app lacks the Instagram permissions (Part A1 step 5). Messenger works meanwhile |
| `Page subscribed to the app` fails, `(200) … pages_manage_metadata` | Token missing that scope (regenerate, Part A2 step 3), then re-run `Test-MetaAccess` (it refreshes the Page token) and `Set-MetaWebhooks` |
| Everything `[OK]`, but Instagram DMs never create a WF-11 run | Check 4 (*Allow access to messages*) is off, or the sender has no role on the app (G3.6) |

> **Fallback, if the owner prefers clicking:** app dashboard → **Use cases** →
> **Customize** (Messenger) → **Messenger API Settings** → *Configure webhooks*:
> Callback URL = the URL above, Verify token = your `SF_META_VERIFY_TOKEN` → **Verify
> and save**; then in *Generate access tokens* → their Page → **Add subscriptions** →
> `messages`, `messaging_postbacks`. For Instagram: **Instagram settings** in the same
> use case → the same URL and token, field `messages`. The result is identical.

---

## G9. First messages, and making yourself the owner

### G9.1 As a patient (Messenger, then Instagram)

Use an account that may talk to the bot in Development mode (G3.6): one of your
friend's dummy accounts, or your own accounts once you've accepted the tester invites.

**Messenger:** in the Messenger app (or messenger.com), search the Page's name, open
the chat and send **"Hi, are you open on Saturday?"**

> Send it **as a person**, not *as the Page*. If the Facebook app has you switched
> into the Page's profile (top-left avatar is the Page logo), switch back first. A
> message from the Page to itself is not a patient message.

Within ~10 seconds you get the hours. n8n → Overview → Executions shows five runs:
WF-11, WF-01, WF-02, WF-10 and WF-09.

**Instagram:** in the Instagram app, open the clinic's profile → **Message** → send
**"Hi, are you open on Saturday?"** Same reply, same five runs. In the WF-11 run,
`FN Verify And Split Events` shows `channel: "instagram"`.

> The first DM from a new account can land in the clinic's **Message requests**
> folder on Instagram. That doesn't matter to the API: the webhook still fires and
> the reply is delivered.

Right now **you are a patient** on both channels: there's no `staff_users` row for
either identity. Good, because that lets you test the patient side first. Do G10
steps 1–3, *then* promote yourself.

### G9.2 Promote yourself to owner

Each channel gives you a different id (PSID on Messenger, IGSID on Instagram). Both
were stored when your first messages arrived:

```sql
SELECT ci.channel, ci.external_contact_id, ci.created_at, c.id AS contact_id
FROM contact_identities ci JOIN contacts c ON c.id = ci.contact_id
WHERE ci.channel IN ('messenger', 'instagram')
ORDER BY ci.created_at DESC;
```

Pick the rows from **your** test messages (match the times). Then, for each channel
you want to be the owner on:

```sql demo
INSERT INTO staff_users (tenant_id, full_name, role, channel, external_contact_id)
SELECT id, 'Owner (Messenger)', 'owner', 'messenger', 'PASTE-YOUR-PSID'
FROM tenants WHERE slug = 'demo_clinic'
ON CONFLICT DO NOTHING;

INSERT INTO staff_users (tenant_id, full_name, role, channel, external_contact_id)
SELECT id, 'Owner (Instagram)', 'owner', 'instagram', 'PASTE-YOUR-IGSID'
FROM tenants WHERE slug = 'demo_clinic'
ON CONFLICT DO NOTHING;
```

paste this:
```sql
INSERT INTO staff_users (tenant_id, full_name, role, channel, external_contact_id)
SELECT id, 'Owner (Messenger)', 'owner', 'messenger', '29093907206887253'
FROM tenants WHERE slug = 'demo_clinic'
ON CONFLICT DO NOTHING;

INSERT INTO staff_users (tenant_id, full_name, role, channel, external_contact_id)
SELECT id, 'Owner (Instagram)', 'owner', 'instagram', '29093907206887253'
FROM tenants WHERE slug = 'demo_clinic'
ON CONFLICT DO NOTHING;
```


That row is the entire difference between "patient" and "owner". Nothing you *say* in
a message can change it (doc 03, layer 1). A good split for demos: be the **owner on
Messenger** and stay a **patient on Instagram**, so you can show both sides from one
phone.

---

## G10. Acceptance tests from your phone

Use a weekday 1–6 days ahead (`Monday` below). Do 1–3 **before** G9.2, while you're
still a patient.

| # | Channel | You send | Expect |
|---|---|---|---|
| 1 | Messenger | "Can I book a cleaning on Monday at 10am?" | Real availability. Free → "Would you like me to book it?"; taken → three nearby times |
| 2 | Messenger | "Yes please, my name is *your name*" | "You're booked: Dental Cleaning on Monday … at 10:00 AM. See you then!" **+ Telegram ping + calendar event** |
| 3 | Instagram | "Can I book a cleaning on Monday at 10am?" | 10:00 is now taken → three alternatives (a different contact, same calendar) |
| 3b | Instagram | pick one of them: "11:00 please, I'm *name*" | Booked on Instagram. **Telegram + calendar.** `appointments.source_channel = 'instagram'` |
| — | | *Do G9.2 now (owner on Messenger)* | |
| 4 | Messenger | "What does Monday look like?" | **Owner answer**: "Monday …: 2 appointments", both bookings with names and phones. **Master-plan step 6** |
| 5 | Instagram | "What does Monday look like?" | **Patient answer**, no schedule (you're still a patient there) |
| 6 | Messenger | "STOP" | Opt-out honoured: "You have been unsubscribed…". Send "START" to undo |
| 7 | Either | A photo or sticker | No reply (MVP ignores non-text). Nothing breaks |

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
Send-MessengerEvent "PASTE-YOUR-IGSID" ("m_test_" + (Get-Random)) "Instagram test: are you open Saturday?" -Instagram
```

`Send-MessengerEvent` (in the helpers) builds the payload Meta would send (`-Instagram`
switches it to an Instagram event for your Instagram account), signs it with the App
Secret from `.env` exactly as Meta does, and posts it to
`http://localhost:5678/webhook/salesfixr/v1/inbound/messenger`.

| Check | Expect |
|---|---|
| Your phone | **One** Messenger reply with the hours (not two), and one Instagram reply |
| Executions | Second WF-11 run stops at `IF New Event` (false). No WF-01 run for it |
| Audit | The forged one is logged: |

```sql
SELECT created_at, workflow, reason_code FROM audit_logs
WHERE workflow IN ('WF-11', 'WF-09') ORDER BY id DESC LIMIT 10;
```

You should see `WF-11 … bad_signature` once, and `WF-09 send ok` rows for the real
replies.

**Clean up** the test bookings (SQL from F8 + delete the calendar events).

---

## G11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Set-MetaWebhooks`: callback verification failed | WF-11 not **Published**; ngrok not running; or verify token mismatch. See G8.1 |
| Webhooks `[OK]`, but messages produce no WF-11 run | Sender has no role on the app (G3.6). For Instagram also: *Allow access to messages* (handoff check 4) |
| Something worked yesterday, today every Graph call fails `(190) … session has been invalidated` | The owner revoked the System User or removed an asset. Ask them; then `Test-MetaAccess` again and update the n8n Page-token credential |
| Every message ends at `PG Log Rejected Webhook`, `bad_signature` | Wrong App Secret in the *Crypto* credential, or Raw Body is off (the HMAC is then computed over the wrong bytes) |
| WF-11 runs, `IF New Event` always false | `clinic_settings.messenger_page_id` (Messenger) or `instagram_account_id` (Instagram) not set or wrong. `account_known` in `PG Claim Event`'s output tells you. Re-run `Test-MetaAccess` for the SQL |
| Instagram reply fails in WF-09 with `(#10)` / `(#200)` | *Allow access to messages* is off (handoff check 4), or the token lacks `instagram_manage_messages` |
| Instagram reply cut short | Instagram's limit is 1000 characters; WF-09 trims to that |
| Bot answers *"I can't check our calendar right now"* | Google Calendar login expired (7-day Testing limit). n8n → Credentials → `SalesFixr Google Calendar` → **Reconnect**. Permanent fix: publish the Google app, E1.2 *Stopping the 7-day logout* |
| Owner asks to book → *"Booking changes from chat are not connected yet"* | Expected: owners/staff can't book through chat yet (and nobody can cancel/reschedule). Test bookings as a patient (G10) |
| WF-01 run happens but no reply on the phone | Look at WF-09's run: `send_failed` with the Graph error. Most common: token expired or for a different Page, wrong `SF_META_GRAPH_VERSION`, or the reply was more than 24 h after the person's last message |
| `HTTP Call WF-01` returns 403 | `WH Inbound Normalized` and `HTTP Call WF-01` aren't using the same `SalesFixr Internal` credential |
| Bot replies to its own messages in a loop | The `is_echo` skip is missing in `FN Verify And Split Events`. Fix immediately: Meta can rate-limit or disable an app that loops |
| Two messages sent quickly, only the first answered | A branch inside the loop doesn't return to `LOOP Each Message` (G6 wiring check) |
| You still get patient answers after G9.2 | Wrong id in `staff_users`, or its `channel` doesn't match the app you're writing from (`messenger` vs `instagram`). Also check `is_active` |
| Replies take > 20 s and Meta retries | WF-11 must use **Respond: Immediately**. If it waits for the brain, Meta times out and retries; idempotency saves you from double answers, but fix the setting |
| Message reaches the Page/Instagram inbox but no WF-11 run | You sent it as the Page, or from an account with no app role (G3.6), or `Set-MetaWebhooks` wasn't run / shows a FAIL (G8) |
| WF-09: `(#10) This message is sent outside of allowed window` | More than 24 h since that person last messaged the Page. Send them a new message first. Expected for proactive messages; see Milestone H |
| Your PowerShell tests now get 403 | Expected after G1. Load `tests\sf-helpers.ps1`; check `SF_INTERNAL_TOKEN` is in `.env` and matches the credential |

---

## Done when

- [ ] G1: internal token credential; `WH-Inbound-Test` protected; unauthenticated call → 403; n8n 2FA on
- [ ] ngrok static domain running; `SF_PUBLIC_BASE_URL` set; `WEBHOOK_URL` unchanged
- [ ] Handoff Part A done by the Page owner; 4 values in `.env`; `Test-MetaAccess` all `[OK]`; migration 006; both ids in `clinic_settings`; both credentials
- [ ] WF-09 and WF-11 built and **Published**; WF-01 has `WH Inbound Normalized`, **Published**
- [ ] `Set-MetaWebhooks` all `[OK]`; `Show-MetaWebhooks` lists `page` and `instagram`
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
