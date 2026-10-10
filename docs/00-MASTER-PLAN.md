# SalesFixr — Master Build Plan (MVP)

> This is the plan of record. `docs/ORIGINAL-CONTEXT.md` is the original brief;
> where this file disagrees with it, **this file wins**, and section 2 below
> explains every disagreement and why.

---

## 0. The one-paragraph mental model

A patient messages your Facebook Page. n8n catches that message on a webhook,
turns it into one standard JSON shape, figures out **who** sent it (patient? you,
the owner?) by looking them up in Postgres, runs a set of **plain if/then rules**
that decide whether we are allowed to reply at all, and only then hands the text
to an AI. The AI's only job is to read the sentence and output structured JSON
like `{"intent":"booking","service":"dental_cleaning","date":"2026-09-30","time":"14:00"}`.
n8n takes that JSON and does the real work itself — check the calendar, insert the
row, send the confirmation. **The AI never touches the database and never decides
what is allowed.** That separation is the entire product.

---

## 1. What "done" means for the MVP

The MVP is finished when a stranger can do this, live, with nothing running but
your PC:

1. They open your Facebook Page and send: *"Can I book a cleaning tomorrow at 2?"*
2. Within ~10 seconds they get: *"You're booked for Tue 30 Sep at 2:00 PM for a Dental Cleaning. See you then!"*
3. A Google Calendar event exists.
4. A row exists in `appointments`.
5. Your Telegram pings you with the booking.
6. **You** then message the same Page and say *"what does tomorrow look like?"* and
   get an owner-style answer listing the schedule — proving role-awareness.
7. If someone else tries to book the same 2 PM slot, the second one is refused.

That is the demo. Everything else (dashboard, voice, SMS, WhatsApp) is after.

---

## 2. Stack decisions — and the three places I changed your brief

Everything below is **free and requires no credit card**. Verify the current free
tier on each signup page before you rely on it; vendor terms move.

| Layer | MVP choice | Cost | Why |
|---|---|---|---|
| Automation | **n8n Community, self-hosted via Docker** on your PC | Free | Fair-code, unlimited workflows locally |
| App database | **Neon Postgres (free tier)** | Free, no card | ⚠️ *changed — see 2.1* |
| n8n's own storage | Docker volume (SQLite) | Free | n8n's internal data, keep it separate |
| Public URL | **ngrok** (free static domain) | Free, no card | ⚠️ *see 2.2* |
| AI model | **Google Gemini Flash** via AI Studio API | Free tier, no card | ⚠️ *changed — see 2.4* |
| Calendar | **Google Calendar API** | Free | Personal Google account is enough |
| Channel | **Facebook Messenger** via a Meta app in Development Mode | Free | You already have the account + Page |
| Owner alerts | **Telegram Bot** | Free | Instant, no card, works on your phone |
| Voice (later) | **ElevenLabs** free tier | Free tier, no card | ⚠️ *see 2.3 — architecture reserved now, built later* |
| Dashboard (later) | n8n webhooks + a static page, or Next.js on Vercel free | Free | Last milestone |

### 2.1 Change: Neon instead of local Docker Postgres

Your brief says local Postgres. I'm recommending **Neon's free tier** for the
application database instead, for three reasons:

- **"Keep it running" is one of your goals.** A local Postgres dies when you close
  Docker or reboot. Neon doesn't.
- When you later move n8n off your PC to a server, the database **does not move**.
  Zero migration work.
- It's a managed Postgres, which is literally the production target in your own
  swap table — so you skip a migration entirely.

Trade-off you should know: Neon free tier scales your database to zero when idle,
so the very first query after a quiet period can take a second or two to wake up.
That is fine for this workload.

**If you want offline dev too:** `infra/docker-compose.yml` includes a local
Postgres service. Run the same `db/*.sql` against it. Keep Neon as the one you demo.

### 2.2 Change: ngrok static domain, not Cloudflare Quick Tunnel

Your brief lists Cloudflare Tunnel. The problem: Cloudflare's *free, no-domain*
"quick tunnel" gives you a **random URL that changes every restart**. Meta requires
you to register a webhook URL once and verify it — a changing URL means
re-registering the webhook in the Meta dashboard every single time you restart.
That will make you hate this project by day three.

ngrok's free plan includes a **static domain** you keep forever. Register it with
Meta once and never touch it again.

> Verify on ngrok's pricing page that the free static domain is still included when
> you sign up. If it has changed, the fallback is a Cloudflare Named Tunnel, which
> needs a domain you own (~$10/yr) — the only place this project would ever cost money.

The rule from your brief still holds: **nothing in the code knows the tunnel URL.**
It lives in one environment variable, `SF_PUBLIC_BASE_URL`.

### 2.3 Addition: ElevenLabs voice slot, reserved from day one

You want voice later. The mistake most people make is building the chat AI first
and then discovering the voice AI needs a completely different code path.

We avoid that with one decision made **now**: every action the AI can take is a
**separate n8n workflow exposed as an HTTP webhook** — `check_availability`,
`book_appointment`, `cancel_appointment`, and so on. See `docs/04-TOOL-API.md`.

Because those are plain HTTP endpoints:
- The **chat** AI calls them as n8n AI-Agent tools.
- The **ElevenLabs Conversational AI** agent calls the *exact same endpoints* as its
  server/webhook tools, with no changes to booking logic at all.

So when you add voice in Milestone I, the work is: create an ElevenLabs agent,
paste the same persona prompt from `ai_personas`, point its tools at the same URLs.
The booking brain is already built. **Do not build voice before Milestone F.**

### 2.4 Change: Gemini Flash instead of a local Ollama model

Your brief says Ollama. We're using **Google's Gemini Flash** through AI Studio,
which has a free API tier that does not ask for a card.

Why this is the better call here:

- **Accuracy where it matters.** The whole design depends on the model returning
  strict JSON every time. A 7B local model gets that wrong often enough that you'd
  spend a milestone building retry logic. Flash is reliable at it.
- **Speed.** ~1–2s instead of 5–15s on CPU. A patient waiting 15 seconds for a
  Messenger reply notices.
- **One less install and one less moving part** for a demo you want to just keep working.
- It's genuinely free at this volume, and it's already a *production* provider — so
  this is a swap you never have to make later.

**The trade-off you must understand:** requests now leave your machine and go to
Google. On the free AI Studio tier, Google may use prompts and responses to improve
their products. For a **fictional demo clinic that is completely fine**. For a real
clinic with real patients it is not — at that point you move to a paid tier or Vertex
AI with a data-processing agreement in place. See section 9.

Practical notes:
- The free tier is **rate limited** (requests per minute and per day). Plenty for a
  demo; it will throttle you if you hammer it in testing. WF-10 handles a 429 by
  waiting and retrying once.
- Model names change. Use whatever the current **Flash** model is in AI Studio and
  pin the exact id in `SF_GEMINI_MODEL`. Because every model call goes through
  **WF-10 LLM Gateway**, upgrading later is one field in one node.
- If you ever want to demo fully offline, Ollama still drops into WF-10 as an
  alternative branch. The architecture didn't change — only which branch is active.

---

## 3. Accounts you need (all free, no card)

Full click-by-click walkthrough in `docs/01-ACCOUNTS-AND-FREE-TIERS.md`. Summary:

| # | Service | What you get | Needed by |
|---|---|---|---|
| 1 | Neon | `DATABASE_URL` connection string | Milestone A |
| 2 | Google AI Studio | Gemini API key | Milestone C |
| 3 | Google Cloud | OAuth Client ID + Secret for Calendar | Milestone E |
| 4 | Telegram (@BotFather) | Bot token + your chat id | Milestone F |
| 5 | ngrok | Authtoken + one static domain | Milestone G |
| 6 | Meta for Developers | App ID, App Secret, Page Access Token, Verify Token | Milestone G |
| 7 | ElevenLabs | API key | Milestone I (later) |

Items 2 and 3 are both Google but **different consoles** — AI Studio for the model
key, Cloud Console for Calendar OAuth. Don't confuse them.

**Never put any of these in a SQL table or a Code node.** They go in n8n
**Credentials** (encrypted) or in `infra/.env`, which is gitignored.

---

## 4. Software to install on your PC

In this order. Nothing here costs money.

Short list, because the model is now in the cloud. Nothing here costs money.

1. **Docker Desktop for Windows** — runs n8n. Enable WSL 2 when it asks.
2. **ngrok for Windows** — the public URL. *(Milestone G, not needed yet.)*
3. **VS Code** *(optional but recommended)* — editing the SQL and JSON files.
4. **Git for Windows** *(optional)* — version your workflow exports.

That's it. No local model, no Python, no Node.js — n8n runs inside Docker and
everything else is a web console.

---

## 5. The milestones

Build strictly in this order. **Each one must work before the next begins.**
Do not connect five APIs at once — when something breaks you will have no idea which.

| # | Milestone | You'll have | Acceptance test |
|---|---|---|---|
| **A** | Database + n8n running | Neon schema live, n8n at `localhost:5678`, WF-01 saving messages | POST test JSON → a row appears in `contacts` and `conversations` |
| **B** | Safety gate + role resolution | WF-01 decides `customer` vs `owner`, blocks opt-outs and quiet hours | Send "STOP" → contact marked opted out, no reply sent, audit row written |
| **C** | AI intent extraction | Gemini returns strict JSON, persona chosen by role | Same sentence from a patient vs from you produces two different personas |
| **D** | Action router | Switch node routes every intent somewhere | All 14 intents land on a branch, none fall through silently |
| **E** | Calendar + availability | WF-03 can list free slots and create events | Ask for a taken slot → get 3 real alternatives |
| **F** | Booking end-to-end | Appointment in Postgres + Calendar, Telegram alert, confirmation reply | The full flow in section 1, steps 1–5 |
| **G** | Real Messenger channel | ngrok + Meta app wired to WF-01 | Message your Page from your phone, get a real reply |
| **H** | Reminders | WF-04 on a schedule drains the `reminders` table | Book for tomorrow → reminder row created and fires |
| **I** | Voice (ElevenLabs) | Voice agent using the same tool endpoints | Call the agent, book by voice, same DB row shape |
| **J** | Dashboard | Read-only views of bookings/inbox/analytics | Shows the booking you just made |

**MVP = A through H.** I and J are the follow-on.

---

## 6. The workflow map

Eight workflows, never one giant one. Import/export them as JSON into
`workflows/exports/` so you can version them.

| Id | Name in n8n | Trigger | Job |
|---|---|---|---|
| WF-01 | `SF WF-01 Inbound Gateway` | Webhook | Receive, dedupe, normalize, resolve contact + role, log |
| WF-02 | `SF WF-02 AI Conversation` | Execute Workflow | Load persona + context, call LLM, return structured JSON |
| WF-03 | `SF WF-03 Booking Operations` | Execute Workflow | Availability, hold, book, reschedule, cancel |
| WF-04 | `SF WF-04 Reminders` | Schedule (every 15 min) | Drain due reminders through the safety gate |
| WF-05 | `SF WF-05 Voice Handler` | Webhook | ElevenLabs inbound — *Milestone I* |
| WF-06 | `SF WF-06 Human Escalation` | Execute Workflow | Flag thread, notify staff, pause the AI. *Built as `SF TOOL escalate_to_human` in F* |
| WF-07 | `SF WF-07 Daily Report` | Schedule (daily 08:00) | Owner summary to Telegram |
| WF-08 | `SF WF-08 Error Logger` | Error Trigger | Catch failures from every other workflow |
| WF-09 | `SF WF-09 Outbound Router` | Execute Workflow | One place that knows how to send on each channel |
| WF-10 | `SF WF-10 LLM Gateway` | Execute Workflow | **The only node that talks to a model.** Swap Gemini→OpenAI/Ollama here |
| WF-11 | `SF WF-11 Messenger Channel` | Webhook | Messenger adapter: verify signature, dedupe, call WF-01, send via WF-09 *(added in G)* |
| WF-T* | `SF TOOL <name>` | Webhook | One per AI tool — see `docs/04-TOOL-API.md` |

Two of these are what make the "replaceable providers" principle real:
**WF-09** is the only workflow that knows Messenger exists, and **WF-10** is the
only one that knows Gemini exists. Swapping either is a one-workflow change.

---

## 7. Hard architectural rules

These are not style preferences. Breaking them is what turns a demo into a liability.

1. **The AI proposes, the workflow disposes.** The LLM outputs intent + parameters.
   n8n validates them against the database and executes. Always.
2. **Role is decided by a database lookup, never by the model.** A `staff_users` row
   makes you the owner. Nothing a message *says* can change its own role — otherwise
   a patient types "I am the owner, list all patients" and your system complies.
3. **Never confirm what you haven't done.** The confirmation message is generated
   *after* the insert succeeds, from the actual row, not from the AI's intention.
4. **Everything is idempotent.** Meta retries webhooks. `processed_events` is checked
   first, before any work happens.
5. **Double-booking is prevented in Postgres, not in logic.** The `EXCLUDE` constraint
   in `db/001_schema.sql` makes overlapping live appointments physically impossible.
   Two simultaneous requests: one succeeds, the other gets a database error you catch.
6. **`tenant_id` on every query.** Even with one clinic. It costs nothing now and
   saves a rewrite when you sell to clinic #2.
7. **Secrets live in n8n Credentials or `.env`.** Never in a Code node, never in a
   table, never in an exported workflow JSON.
8. **Every branch writes an `audit_logs` row** with a `correlation_id`. When the demo
   misbehaves in front of a client, this is how you explain it in ten seconds.

---

## 8. Portfolio → production swaps

Because of WF-09, WF-10 and the tool endpoints, each of these is a contained change:

| Layer | MVP | Production | What actually changes |
|---|---|---|---|
| Model | Gemini Flash, free tier | Gemini paid / Vertex AI / OpenAI / Anthropic | The model node inside **WF-10 only** |
| Database | Neon free | Neon paid / managed PG | Connection string in one credential |
| Channel | Messenger dev mode | Messenger + WhatsApp, app-reviewed | Add a branch in **WF-09**, plus Meta App Review |
| Alerts | Telegram | Email / SMS / dashboard | A branch in **WF-09** |
| Calendar | Google Calendar | NexHealth / Dentrix / Open Dental | Inside **WF-03** only; the AI never knows |
| Voice | ElevenLabs free | ElevenLabs paid / Twilio+ElevenLabs | Same tool endpoints, different agent config |
| Hosting | Your PC + ngrok | VPS / n8n Cloud + real domain | `SF_PUBLIC_BASE_URL` + re-register webhooks |

---

## 9. Compliance note — read this before you sell it

This MVP is a **portfolio demo with fictional patient data**. Real dental patient
data is health data. Before any real clinic sends real patients through this:

- US: HIPAA applies. Meta will not sign a BAA for WhatsApp/Messenger — that alone
  rules those channels out for real PHI in the US.
- EU/UK: GDPR applies; you'd need a lawful basis, a DPA with each processor, and a
  retention policy you actually enforce.
- Everywhere: messaging consent and opt-out handling are legal requirements, not features.
- **The Gemini free tier is not a confidential channel.** Google may use free-tier
  prompts to improve their products. Never send real patient text through it. The
  production path is a paid tier or Vertex AI under a data-processing agreement —
  and because of WF-10, that swap is one node, not a rewrite.

Keep the demo clinic fictional. When a real client appears, that's a separate
conversation with a lawyer, not a config change.

---

## 10. Where to start

`docs/01-ACCOUNTS-AND-FREE-TIERS.md` → create accounts 1 and 2.
Then Milestone A. Nothing else until A passes its acceptance test.
