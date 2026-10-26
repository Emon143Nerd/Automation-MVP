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

**What it is:** gives your `localhost:5678` a fixed public https address so
Facebook can reach it. Free plan, no card, one free static domain.

**Step by step:** `docs/11-MILESTONE-G.md` §G2 (kept in one place so it can't
drift out of date).

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

## 7. Meta — Facebook Messenger + Instagram DMs  *(Milestone G)*

**You don't create a Meta account or log in for this.** The owner of the Page and
Instagram account (your friend for the portfolio, the client later) creates a
**System User** token in their Business Manager and sends you 4 values: App ID, App
secret, System user token, Page ID. Send them `docs/META-ACCESS-HANDOFF.md`.

Free while the app stays in **Development mode**: the bot then answers people with a
role on the app (admins/testers) and Page admins, which is enough for building and
demos. Answering the general public needs App Review + Business Verification
(post-MVP; see Milestone G, Appendix B).

**Step by step:** `docs/11-MILESTONE-G.md` §G3 (access, checked by
`tests\meta-setup.ps1`) and §G8 (webhook, also from PowerShell).

> **2026 change:** Meta retired the `CONFIRMED_EVENT_UPDATE`, `ACCOUNT_UPDATE`
> and `POST_PURCHASE_UPDATE` message tags. Messages we start ourselves (reminders)
> are only possible within 24 h of the patient's last message, or later through
> Meta's approved *utility message* templates. Milestone H is designed around this.

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
