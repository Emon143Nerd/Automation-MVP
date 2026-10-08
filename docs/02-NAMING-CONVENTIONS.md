# Naming Conventions

Boring and consistent beats clever. When a workflow has 40 nodes and something
breaks at 11 PM before a client demo, names are the only thing that saves you.

---

## 1. Workflows

`SF WF-NN <Purpose>` — e.g. `SF WF-01 Inbound Gateway`

- `SF` prefix so they sort together and survive being imported next to other people's workflows.
- Two-digit number so `WF-10` doesn't sort before `WF-02`.
- Tool workflows: `SF TOOL <verb_noun>` — e.g. `SF TOOL check_availability`.

**Tags** (n8n workflow tags): `salesfixr`, plus one of `core`, `tool`, `scheduled`, `channel`.

---

## 2. Nodes

`<TYPE> <What it does>` — always a verb or a question. Never leave `Postgres1`.

| Prefix | Node type | Example |
|---|---|---|
| `WH` | Webhook | `WH Inbound Messenger` |
| `TRG` | When Executed by Another Workflow (sub-workflow start) | `TRG Called By Workflow` |
| `RESP` | Respond to Webhook | `RESP 200 EchoChallenge` |
| `SET` | Edit Fields / Set | `SET Normalized Message` |
| `FN` | Code | `FN Normalize Messenger Payload` |
| `IF` | If | `IF Contact Exists` |
| `SW` | Switch | `SW Route By Intent` |
| `PG` | Postgres | `PG Find Contact By Identity` |
| `GC` | Google Calendar | `GC Get Events For Day` |
| `TG` | Telegram | `TG Notify Owner Booking` |
| `HTTP` | HTTP Request | `HTTP Send Messenger Reply` |
| `SUB` | Execute Workflow | `SUB Call WF-03 Booking` |
| `AI` | AI Agent / model | `AI Extract Intent` |
| `WAIT` | Wait | `WAIT Hold TTL` |
| `ERR` | Stop and Error | `ERR Slot Already Taken` |
| `MERGE` | Merge | `MERGE Contact And Settings` |

Rules:
- Node names appear in n8n expressions (`$('PG Find Contact By Identity').item.json.id`).
  **Renaming a node breaks every expression referencing it.** Name it right the first time.
- If two nodes do the same thing on different branches, suffix the branch:
  `PG Insert Contact (new)`.

---

## 3. Webhook paths

```
/webhook/salesfixr/v1/<area>/<name>
```

| Purpose | Path |
|---|---|
| Messenger inbound | `/webhook/salesfixr/v1/inbound/messenger` |
| Test inbound (dev) | `/webhook/salesfixr/v1/inbound/test` |
| WhatsApp (later) | `/webhook/salesfixr/v1/inbound/whatsapp` |
| Voice (later) | `/webhook/salesfixr/v1/inbound/voice` |
| AI tool endpoints | `/webhook/salesfixr/v1/tool/<tool_name>` |

The `v1` is there so you can add `v2` later without breaking a registered Meta webhook.

n8n also gives every webhook a `/webhook-test/...` variant that only fires while you
have the canvas open in "Listen for test event" mode. **Register the `/webhook/`
production path with Meta**, not the test one.

---

## 4. Database

- Tables: `snake_case`, **plural** — `contacts`, `audit_logs`.
- Columns: `snake_case`, singular — `full_name`, `start_time`.
- Primary key: always `id` (uuid).
- Foreign key: `<singular_table>_id` — `contact_id`, `tenant_id`.
- Booleans read as a statement: `is_active`, `opted_out`, `marketing_consent`.
- Timestamps end in `_at`: `created_at`, `hold_expires_at`. Always `timestamptz`, always UTC.
- Durations end in their unit: `duration_minutes`, `offset_hours`, `hold_ttl_minutes`.
- Money in **minor units** as an integer: `price_minor` (15000 = $150.00 USD).
  Never store money as a float.
- Enums end in `_t`: `channel_t`, `intent_t`.
- Indexes: `<table>_<purpose>_idx`; unique: `<table>_<cols>_uq`.

---

## 5. The normalized message envelope

Every channel is converted to exactly this shape by WF-01. Downstream workflows
never see a provider payload.

```json
{
  "correlation_id": "c8f2a1e0-...",
  "tenant_slug": "demo_clinic",
  "tenant_id": "uuid",
  "channel": "messenger",
  "external_contact_id": "7250123456789012",
  "external_message_id": "m_AbC123...",
  "actor_role": "customer",
  "contact_id": "uuid-or-null",
  "staff_user_id": null,
  "name": "John Smith",
  "phone_e164": null,
  "message": "Can I book a cleaning tomorrow at 2?",
  "message_type": "text",
  "received_at": "2026-09-29T08:00:00.000Z",
  "reply_to": { "channel": "messenger", "address": "7250123456789012" }
}
```

- `correlation_id` — one uuid generated at the webhook, carried through every
  workflow and written into every `audit_logs` row for this message. This is your
  debugging superpower.
- `actor_role` — set by a **database lookup**, never by the model.
- `reply_to` — how WF-09 sends the answer back. Channel-specific detail stops here.

---

## 6. Environment variables

Prefix `SF_`, SCREAMING_SNAKE_CASE, grouped by provider. See `infra/.env.example`.

```
SF_DATABASE_URL
SF_PUBLIC_BASE_URL
SF_OLLAMA_BASE_URL
SF_OLLAMA_MODEL
SF_TELEGRAM_BOT_TOKEN
SF_META_PAGE_TOKEN
```

---

## 7. Audit reason codes

Fixed vocabulary, so you can `GROUP BY reason_code` later:

```
opted_out            quiet_hours          rate_limited
no_consent           duplicate_event      unknown_tenant
slot_taken           slot_outside_hours   lead_time_too_short
service_unknown      past_date            hold_expired
llm_invalid_json     llm_timeout          llm_error
tool_not_allowed
escalated_medical    escalated_requested  ok
```

---

## 8. Git

```
docs/      the plan and reference — commit
db/        numbered migrations, append-only — commit
infra/     docker-compose + .env.example — commit (.env NEVER)
workflows/exports/   SF_WF-01_inbound-gateway.json — commit
assets/    diagrams — commit
```

Migrations are `NNN_description.sql`, numbered, **never edited after they've been run**.
Need a change? Add `003_add_whatever.sql`.

Commit workflow exports after each milestone passes. `git log` then doubles as your
build journal for the portfolio write-up.
