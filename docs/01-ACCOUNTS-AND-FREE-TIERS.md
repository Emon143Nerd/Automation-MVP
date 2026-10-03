# Accounts & Free Tiers — click-by-click

Every service here is free and **does not ask for a card** for what we need.
Where a vendor could plausibly have changed its free tier since this was written,
there's a ⚠️ — check the page before you rely on it.

Create them **in milestone order**, not all at once. Each one has a "you'll know it
worked when" test. Do the test. Don't skip ahead with an unverified credential;
debugging four broken integrations at once is how projects die.

As you collect values, write them into `infra/.env` (copy from `infra/.env.example`).
That file is gitignored and never leaves your machine.

---

## 1. Neon — the database  *(Milestone A)*

**What it is:** a Postgres database in the cloud that stays alive when your PC sleeps.

1. Go to **https://neon.com** → *Sign up* → sign in with GitHub or Google.
   No card is requested on the free plan. ⚠️ confirm at https://neon.com/pricing
2. It will create a project for you. Name it **`salesfixr`**.
   - Postgres version: latest offered is fine.
   - Region: pick the one nearest you.
3. On the project dashboard, find **Connection string** (sometimes under *Connect*).
   Copy the one labelled **pooled** if there is a choice.
   It looks like:
   `postgresql://neondb_owner:XXXXXXXX@ep-something-123456-pooler.region.aws.neon.tech/neondb?sslmode=require`
4. Paste it into `infra/.env` as `SF_DATABASE_URL=`.
5. Open the **SQL Editor** in the Neon dashboard.
   Paste the whole of `db/001_schema.sql`, run it. Then `db/002_seed_demo_clinic.sql`, run it.

**You'll know it worked when:** running `SELECT slug, display_name FROM tenants;`
returns one row, `demo_clinic / SmileCare Dental`, and
`SELECT role, data_scope FROM ai_personas;` returns three rows.

> **Free tier shape (verify current numbers):** roughly 0.5 GB storage and a
> generous monthly compute allowance — far more than this project uses.
> The database auto-suspends when idle and wakes on the next query.

---

## 2. Docker Desktop — runs n8n  *(Milestone A)*

Not an account, an install, but it belongs here.

1. https://www.docker.com/products/docker-desktop/ → download for Windows.
2. Install. When it offers **WSL 2**, accept it. Reboot if asked.
3. Open Docker Desktop once and let it finish starting (whale icon steady in the tray).

**You'll know it worked when:** in PowerShell, `docker run --rm hello-world` prints
a "Hello from Docker!" message.

> Docker Desktop is free for personal use and small businesses. ⚠️ Their license
> threshold changes occasionally; at your scale it is free.

---

## 3. Google AI Studio — the AI model  *(Milestone C)*

**What it is:** an API key for Google's Gemini models. Free tier, no card.
This is **not** the same console as Google Cloud (section 5) — different site,
different key. Don't mix them up.

1. Go to **https://aistudio.google.com** → sign in with your Google account.
2. **Get API key** → *Create API key*. If it asks for a project, let it create one.
3. Copy the key (starts with `AIza...`) → `.env` as `SF_GEMINI_API_KEY=`.
4. In AI Studio's model list, find the current **Flash** model and copy its exact
   id — e.g. `gemini-2.5-flash`. Put it in `.env` as `SF_GEMINI_MODEL=`.
   ⚠️ Google renames models often. Use whatever Flash model is current when you read
   this; it is a one-line change later because every call goes through WF-10.

**You'll know it worked when:** this returns a response containing the word `OK`.
Paste it into PowerShell and substitute your key:

```powershell
$key = "YOUR_KEY_HERE"
$model = "gemini-2.5-flash"
$body = @{ contents = @(@{ parts = @(@{ text = "Reply with only the word OK" }) }) } | ConvertTo-Json -Depth 10
$r = Invoke-RestMethod -Method Post -Uri "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" -Headers @{ "x-goog-api-key" = $key } -ContentType "application/json" -Body $body
$r.candidates[0].content.parts[0].text
```

> ⚠️ **Do not use `curl` in Windows PowerShell 5.1.** `curl` there is an *alias for
> `Invoke-WebRequest`*, which does not understand `-H` or `-d` — you'll get a
> confusing parameter error that looks like an API problem but isn't. If you want
> real curl, call it as **`curl.exe`** explicitly. Every example in these docs uses
> `Invoke-RestMethod` or `curl.exe` for this reason.

> **Free tier shape (verify at https://ai.google.dev/pricing):** free of charge with
> per-minute and per-day request limits. Far more than a demo needs — but you *can*
> hit the per-minute cap while rapid-testing. WF-10 retries once on a 429.
>
> **Privacy:** on the free tier Google may use your prompts to improve their
> products. Keep the demo clinic fictional. Never send real patient data through a
> free-tier key. See `docs/00-MASTER-PLAN.md` §9.

---

## 4. ngrok — the public URL  *(Milestone G)*

**What it is:** gives your `localhost:5678` a real https address on the internet so
Facebook can reach it.

1. https://ngrok.com → *Sign up free*. No card. ⚠️ confirm at https://ngrok.com/pricing
2. Dashboard → **Your Authtoken** → copy it.
3. Dashboard → **Domains** → create your free **static domain**.
   You'll get something like `honest-koala-12ab.ngrok-free.app`. This never changes.
4. Install: https://ngrok.com/download (or `winget install ngrok.ngrok`).
5. Register the token once:
   ```
   ngrok config add-authtoken YOUR_TOKEN_HERE
   ```
6. Start the tunnel (leave this window open whenever you're demoing):
   ```
   ngrok http --domain=honest-koala-12ab.ngrok-free.app 5678
   ```
7. Put the https URL in `infra/.env` as `SF_PUBLIC_BASE_URL=`.

**You'll know it worked when:** opening `https://your-domain.ngrok-free.app` in a
browser shows the n8n login screen.

> ⚠️ If the free static domain is no longer offered, tell me and we'll switch to a
> Cloudflare Named Tunnel — that needs a domain you own, the only paid piece in the
> whole project.

---

## 5. Google Calendar API  *(Milestone E)*

**What it is:** OAuth access so n8n can read and create events on a calendar.

**Use a dedicated calendar, not your personal one.** In Google Calendar, create a
new calendar named **`SalesFixr — SmileCare Dental`**. Open its settings and copy
the **Calendar ID** (looks like `abc...@group.calendar.google.com`).

1. https://console.cloud.google.com → accept terms → **New Project** →
   name it `salesfixr`. No billing account is needed for the Calendar API.
2. **APIs & Services → Library** → search *Google Calendar API* → **Enable**.
3. **APIs & Services → OAuth consent screen**
   - User type: **External**
   - App name: `SalesFixr`, your email for support and developer contact.
   - Scopes: you can leave empty here; n8n requests them at connect time.
   - **Test users:** add your own Gmail address. ← *do not skip this*
   - Leave the app in **Testing** status. That's fine and free; it means only your
     listed test users can authorize it, which is all you need.
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID**
   - Application type: **Web application**
   - Name: `SalesFixr n8n`
   - **Authorized redirect URI:** n8n shows you the exact URL to paste when you
     create the Google Calendar credential — copy it from n8n and paste it here.
     While developing locally it is typically
     `http://localhost:5678/rest/oauth2-credential/callback`.
5. Copy the **Client ID** and **Client Secret** into `infra/.env`.

**You'll know it worked when:** in n8n, the Google Calendar credential shows
*Connected*, and a Google Calendar node set to *Get Many* events returns your
(empty) calendar without an error.

---

## 6. Telegram Bot — owner alerts  *(Milestone F)*

1. In Telegram, message **@BotFather**.
2. `/newbot` → name it `SalesFixr Alerts` → username must end in `bot`,
   e.g. `salesfixr_alerts_bot`.
3. BotFather gives you a **token** like `1234567890:AAH...`. Into `.env` as
   `SF_TELEGRAM_BOT_TOKEN=`.
4. **Send your new bot any message** ("hi"). A bot cannot message you first.
5. Get your chat id — open in a browser:
   `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates`
   Find `"chat":{"id":123456789,...}`. That number is `SF_TELEGRAM_CHAT_ID`.

**You'll know it worked when:** opening
`https://api.telegram.org/bot<TOKEN>/sendMessage?chat_id=<ID>&text=hello`
makes "hello" appear in your Telegram.

---

## 7. Meta for Developers — Facebook Messenger  *(Milestone G)*

This is the fiddliest one. Read it all before starting.

**The key fact that makes this free and reviewable-later:** while your Meta app is
in **Development mode**, it can exchange messages with people who have a **role on
the app** (admin / developer / tester) and with **admins of the connected Page**.
That is enough for you, your test account, and a client demo. Messaging the *general
public* requires App Review for `pages_messaging`, which is a Milestone-after-MVP
concern. ⚠️ Meta's dashboard layout and product names change often — if a label
below doesn't match what you see, tell me what you see and I'll re-map it.

**Prerequisites:** a Facebook **Page** (not a personal profile) that you administer.

1. https://developers.facebook.com → *Get Started* with your Facebook account.
2. **My Apps → Create App**.
   - Use case: choose the one offering **Messenger / messaging** (recently phrased
     as *"Other" → "Business"*).
   - App name: `SalesFixr Dev`. Contact email: yours.
3. In the app dashboard, **add the Messenger product**.
4. **Messenger → Settings → Access Tokens** (or *Generate token*):
   - **Connect your Page** → pick your Page → grant the permissions it asks for.
   - Generate a **Page Access Token**. Copy it → `.env` as `SF_META_PAGE_TOKEN=`.
   - Also note the **Page ID** → `SF_META_PAGE_ID=`.
5. **App Settings → Basic**: copy **App ID** and **App Secret** →
   `SF_META_APP_ID=`, `SF_META_APP_SECRET=`.
   (The secret is used to verify the `X-Hub-Signature-256` header so nobody can
   forge messages into your webhook. We do check it.)
6. **Invent a verify token.** Any random string you make up, e.g.
   `sf_verify_9c2f81ab`. Put it in `.env` as `SF_META_VERIFY_TOKEN=`. Meta will echo
   it back at you during webhook setup, and WF-01 must return it unchanged.
7. **Messenger → Settings → Webhooks → Add Callback URL.** Do this only *after*
   WF-01 is built and ngrok is running, or verification will fail.
   - Callback URL: `https://your-domain.ngrok-free.app/webhook/salesfixr/v1/inbound/messenger`
   - Verify Token: the string from step 6.
   - Subscribe the Page to these fields: **`messages`**, **`messaging_postbacks`**,
     and (optional) `message_reactions`.

**You'll know it worked when:** Meta shows the webhook as *Complete/Verified*, and
sending a message to your Page from your own Facebook account produces an n8n
execution with a `sender.id` (that's the **PSID**) in the payload.

> **Save your own PSID.** Take the `sender.id` from that first execution and run the
> commented-out `INSERT INTO staff_users ...` at the bottom of
> `db/002_seed_demo_clinic.sql` with it. That single row is what makes the AI
> treat you as the owner. Until you do it, you're just another patient to the system.

---

## 8. ElevenLabs — voice  *(Milestone I, later)*

Do not create this until Milestone F passes. Listed now only so you know the slot exists.

1. https://elevenlabs.io → sign up free. No card on the free tier.
   ⚠️ confirm the current free monthly credit allowance at https://elevenlabs.io/pricing
2. Profile → **API Keys** → create one → `.env` as `SF_ELEVENLABS_API_KEY=`.
3. Later we create a **Conversational AI agent** there and point its **server tools**
   at the same `SF TOOL ...` webhook URLs the chat AI already uses. The booking logic
   is not rewritten.

> Free-tier voice usually carries attribution requirements and limited concurrency.
> Fine for a demo, not for a production phone line.

---

## Credential hygiene — non-negotiable

- `infra/.env` is **gitignored**. Never commit it. Never paste its contents into a chat,
  a screenshot, or a workflow export.
- Inside n8n, secrets belong in **Credentials**, not in Code or HTTP node fields.
- Before sharing a workflow JSON for your portfolio, open it and confirm no token
  strings are in it. n8n exports credential *references*, not values — but a token
  you typed into an HTTP node's header field **will** be in there.
- If a token leaks: Meta → regenerate Page token; Telegram → `/revoke` in BotFather;
  Neon → reset the role password; ngrok → rotate the authtoken.
