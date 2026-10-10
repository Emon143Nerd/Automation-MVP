# Milestone F — Booking End-to-End

**Goal:** the demo from the master plan, steps 1–7, working on the test channel:

1. A patient asks for a time → gets real availability (E).
2. They say *"yes"* (or pick one of the offered times) → **the appointment is
   booked**: held in Postgres, created on Google Calendar, confirmed.
3. The confirmation they read is generated **from the database row**, never from
   the AI.
4. Your Telegram pings with the booking.
5. Reminder rows are created (Milestone H sends them).
6. **You** (the owner) ask *"What does Monday look like?"* and get the real schedule.
7. A second patient trying the same slot is refused.

Plus the honest version of "let me get a human": the owner gets a Telegram alert
and the AI goes quiet on that thread.

**Why now:** E made the bot truthful about availability. F lets it *act*, and
acting is where a booking bot earns or loses trust. Every rule from the master plan
gets exercised here: *the AI proposes, the workflow disposes*, *never confirm what
you haven't done*, *double-booking is prevented in Postgres*.

**Time:** about 4 hours. Three small tool workflows (mostly copied from E) plus
eight focused edits in WF-02. Do it in two sittings: F1–F6 (tools, tested by hand),
then F7–F8 (wiring and end-to-end).

**Prerequisite:** Milestone E green: `SF TOOL check_availability` published and
passing T1–T8; WF-02 offering real alternatives in chat.

---

## F0. What gets built

### The two-step booking, and why it's two steps

```
Patient: "Can I book a cleaning on Monday at 10?"
   → router: check_availability → tool says 10:00 is free
   → bot: "Good news: 10:00 AM on Monday 12 October is free for a Dental Cleaning.
           Would you like me to book it?"
   → WF-02 saves a BOOKING OFFER: { service, day, [10:00] }, valid 30 minutes

Patient: "yes please"
   → the AI sees the PENDING OFFER in its context and fills in service/date/time
   → router: those match an offered slot → route "book"
   → book_appointment tool: hold → Google Calendar → booked → reminders → Telegram
   → bot: "You're booked: Dental Cleaning on Monday 12 October at 10:00 AM. See you then!"
           ↑ built from the appointments row the tool just wrote
```

The bot **never books on the first message**, even when the time is free. A booking
creates a calendar event, sends the owner an alert and (from H) schedules messages
to the patient. Doing that because the model misread "can I book…?" as "book it"
would be the expensive kind of mistake. The offer-then-accept step means the
patient always explicitly chose the exact slot they're booked into. That slot also
came from the tool, not from the model.

**Why the offer is stored in the database, not left to the AI's memory:** the
model *could* read "you offered 10:00" from the conversation history. But then
"what was offered" would be the model's recollection. With a `booking_offers` row,
the router checks the patient's choice against **exactly** the slots the tool
returned. A model that hallucinates "11:00" when only 10:00 was offered doesn't get
a booking. It gets a fresh availability check.

### New pieces

| Piece | Kind | Job |
|---|---|---|
| `db/005_booking_offers.sql` | migration | The `booking_offers` table |
| `SF TOOL book_appointment` | tool workflow | Hold → calendar → book → reminders → Telegram |
| `SF TOOL escalate_to_human` | tool workflow | Pause the AI on that thread + Telegram the owner (the job WF-06 had in the master plan) |
| `SF TOOL get_schedule` | tool workflow | A day's appointments, owner/staff only |
| WF-02 edits | 8 changes | Offer in context, `book` route, three new branches |

### The booking tool, step by step

```
WH → FN Validate Tool Request → IF Request Accepted ─false→ RESP Tool Rejected
   → PG Load Booking Context        validate the slot + release expired holds
   → FN Decide Booking → IF Place Hold ─false──────────────────────────┐
   → PG Place Hold                  INSERT … ON CONFLICT DO NOTHING    │
   → IF Hold Placed ─false (slot taken) ───────────────────────────────┤
   → GC Create Event                                                   │
   → IF Event Created ─false (calendar failed) ────────────────────────┤
   → PG Confirm Booking             held→booked, reminders, offer used │
                                                                       ↓
                                       FN Booking Result  ← every path ends here
                                       → IF Booked ─true→ TG Notify Owner ─┐
                                              └─false──────────────────────┤
                                       → PG Write Tool Audit → RESP Tool Result
```

This is the order from `docs/04-TOOL-API.md`, and **the order matters**:

1. **Hold first.** The `INSERT` is where the double-booking constraint fires. If two
   patients go for 10:00 at the same moment, Postgres lets exactly one insert
   through. The other gets *zero rows* and becomes `slot_taken`.
2. **Calendar second.** Only a patient who *won* the slot causes a calendar event.
3. **Confirm third.** `held` → `booked` only after the calendar event exists.

If the calendar step fails, the row stays `held` with a 5-minute expiry and is
released automatically. No orphan bookings, no calendar event for a booking that
doesn't exist.

---

## F1. Setup

### F1.1 Telegram bot  (doc 01 §6)

Follow `docs/01-ACCOUNTS-AND-FREE-TIERS.md` §6 to create the bot and find your
chat id. Then:

**n8n credential:** Credentials → Create → **Telegram API**.

| Field | Value |
|---|---|
| Credential name | `SalesFixr Telegram` |
| Access Token | the BotFather token (`1234567890:AAH…`) |

**Tell the database where alerts go.** The chat id belongs to the clinic, so it
lives in `clinic_settings` (the column has existed since Milestone A). It doesn't
go in `.env`: when you onboard clinic #2, their alerts go to *their* Telegram.

```sql
UPDATE clinic_settings
   SET telegram_chat_id = 'PASTE-YOUR-CHAT-ID'
 WHERE tenant_id = (SELECT id FROM tenants WHERE slug = 'demo_clinic');
```

### F1.2 Migration 005

Run `db/005_booking_offers.sql` in the Neon SQL Editor. Check:

```sql
SELECT column_name FROM information_schema.columns
WHERE table_name = 'booking_offers' ORDER BY ordinal_position;
```

---

## F2. New things in this milestone — read once

### Telegram node — we name it `TG …`

*Node picker → **Telegram** → **Send a text message**.* Uses the `SalesFixr
Telegram` credential. Fields: **Chat ID** and **Text**. Under **Additional
Fields**, turn **Append n8n Attribution** off, or every alert ends with "This
message was sent automatically with n8n".

**Every Telegram node in this project is set to On Error → Continue.** An alert is
a courtesy. If Telegram is down, the patient's booking must still succeed and be
confirmed. Never let a notification failure undo real work.

### Duplicating a workflow

All three tools in this milestone share the shape of `SF TOOL check_availability`:
webhook → validate → IF → reject / work → audit → respond. Don't rebuild that by
hand. Open `SF TOOL check_availability` → **⋯** (top right) → **Duplicate** →
give the new name. Then change the webhook **path** first (two webhooks with the
same path conflict), and replace the nodes this guide lists. The rest stays as it
is.

### `ON CONFLICT DO NOTHING` on an exclusion constraint

Normally an `INSERT` that violates the no-overlap constraint throws an error, and
the Postgres node fails. Adding `ON CONFLICT DO NOTHING` changes "error" into
"inserted zero rows", with the **same** safety guarantee. Postgres still decides,
atomically, who gets the slot. We wrap it so the query always returns exactly one
row (`appointment_id` filled, or `null` when the slot was taken). The next IF node
reads that, with no error handling needed.

### Nodes with many inputs, and `isExecuted`

`FN Booking Result` has four incoming connections: one per way the booking can
end. Only one of them runs per call. Inside, the code asks
`$('PG Place Hold').isExecuted` (and so on) to work out which path it came from.
This is the same pattern as WF-01's `RESP Ack` from Milestone C.

---

## F3. Tool — `SF TOOL book_appointment`

Duplicate `SF TOOL check_availability` → name it **`SF TOOL book_appointment`**.
**Delete** nodes 5–9 of the copy (`PG Load Availability Context` through
`RESP Tool Result`). You'll rebuild them below. Keep the webhook, validator, IF
and rejected response.

### Node 1 — `WH Tool Book Appointment`  (Webhook)

Rename, and change **Path** to `salesfixr/v1/tool/book_appointment`. Everything else
as in E.

### Node 2 — `FN Validate Tool Request`  (Code, replace the code)

```javascript
// FN Validate Tool Request — book_appointment
// Contract rules 1 and 4. The patient is ALWAYS context.contact_id (from the
// authenticated envelope), never an argument.

const body = $input.first().json.body || {};
const auth = body.auth || {};
const ctx  = body.context || {};
const args = body.args || {};
const expected = String($env.SF_TOOL_TOKEN || '');
const CHANNELS = ['test', 'messenger', 'whatsapp', 'sms', 'voice', 'web', 'instagram', 'email'];

let gate = 'ok';
let problem = null;
const isInstant = (s) =>
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/.test(s || '') && !isNaN(Date.parse(s));

if (expected.length < 16) {
  gate = 'unauthorized'; problem = 'Tool token is not configured on the server.';
} else if (auth.tool_token !== expected) {
  gate = 'unauthorized'; problem = 'Invalid tool token.';
} else if ('contact_id' in args) {
  gate = 'bad_request'; problem = 'contact_id is not accepted in args.';
} else if (!ctx.correlation_id || !ctx.tenant_slug || !['customer', 'staff', 'owner'].includes(ctx.actor_role)) {
  gate = 'bad_request'; problem = 'context needs correlation_id, tenant_slug and a valid actor_role.';
} else if (!ctx.contact_id) {
  gate = 'bad_request'; problem = 'context.contact_id (the patient being booked) is required.';
} else if (!args.service_code) {
  gate = 'bad_request'; problem = 'args.service_code is required.';
} else if (!isInstant(args.start_time)) {
  gate = 'bad_request'; problem = 'args.start_time must be an ISO instant with a timezone, e.g. 2026-10-12T14:00:00Z.';
}

return [{
  json: {
    gate,
    problem,
    ctx: {
      correlation_id: ctx.correlation_id ?? null,
      tenant_slug:    ctx.tenant_slug ?? null,
      actor_role:     ctx.actor_role ?? null,
      contact_id:     ctx.contact_id ?? null,
      staff_user_id:  ctx.staff_user_id ?? null,
      channel:        CHANNELS.includes(ctx.channel) ? ctx.channel : 'web',
    },
    args: {
      service_code: args.service_code ?? null,
      start_time:   args.start_time ?? null,
      patient_name: typeof args.patient_name === 'string' ? args.patient_name.trim().slice(0, 80) : '',
    },
  },
}];
```

Nodes 3 (`IF Request Accepted`) and 4 (`RESP Tool Rejected`) stay as copied.

---

### Node 5 — `PG Load Booking Context`  (Postgres)

**Settings → Always Output Data: ON.** Connect from `IF Request Accepted` **true**.

The tool must not trust `start_time` just because WF-02 got it from an offer. Voice
will call this tool directly. So it re-checks everything: the role, the patient,
the service, opening hours, the slot grid, lead time. It also releases expired holds
first, so a hold abandoned 10 minutes ago doesn't block the slot.

```sql
WITH t AS (
  SELECT id, timezone FROM tenants WHERE slug = $1 AND is_active
),
-- Release holds whose time ran out (e.g. a calendar call that failed earlier).
-- Runs as its own statement before PG Place Hold, so the insert sees the result.
released AS (
  UPDATE appointments a
     SET status = 'cancelled', cancel_reason = 'hold_expired'
    FROM t
   WHERE a.tenant_id = t.id AND a.status = 'held' AND a.hold_expires_at < now()
  RETURNING a.id
),
s  AS (SELECT cs.* FROM clinic_settings cs JOIN t ON cs.tenant_id = t.id),
sv AS (
  SELECT sv.id, sv.code, sv.display_name, sv.duration_minutes
  FROM services sv JOIN t ON sv.tenant_id = t.id
  WHERE sv.code = $2 AND sv.is_active
),
st AS (SELECT ($3::timestamptz AT TIME ZONE t.timezone) AS local_start FROM t),
bh AS (
  SELECT bh.* FROM business_hours bh, t, st
  WHERE bh.tenant_id = t.id AND bh.weekday = EXTRACT(DOW FROM st.local_start)
)
SELECT
  t.id                                                        AS tenant_id,
  (SELECT p.allowed_tools @> ARRAY['book_appointment']
     FROM ai_personas p
    WHERE p.tenant_id = t.id AND p.role = $4::actor_role_t AND p.is_active) AS tool_allowed,
  (SELECT json_build_object('id', c.id, 'name', c.full_name, 'phone', c.phone_e164)
     FROM contacts c WHERE c.id = NULLIF($5, '')::uuid AND c.tenant_id = t.id) AS contact,
  (SELECT row_to_json(x) FROM sv x)                           AS service,
  s.telegram_chat_id,
  s.max_days_in_advance,
  ($3::timestamptz < now() + make_interval(mins => s.min_lead_time_minutes)) AS too_soon,
  (st.local_start::date - (now() AT TIME ZONE t.timezone)::date)            AS days_ahead,
  (SELECT bh.is_closed FROM bh)                               AS closed,
  (SELECT st.local_start::time >= bh.opens_at
      AND st.local_start::time + make_interval(mins => (SELECT duration_minutes FROM sv)) <= bh.closes_at
     FROM bh)                                                 AS within_hours,
  (SELECT (EXTRACT(EPOCH FROM (st.local_start::time - bh.opens_at)) / 60)::int
          % s.slot_granularity_minutes = 0 FROM bh)           AS on_grid,
  to_char(st.local_start, 'FMDay DD FMMonth')                 AS day_label,
  to_char(st.local_start, 'FMHH12:MI AM')                     AS time_label,
  (SELECT count(*) FROM released)                             AS holds_released
FROM t, s, st;
```

**Query Parameters:**

```
{{ [ $json.ctx.tenant_slug, $json.args.service_code, $json.args.start_time, $json.ctx.actor_role, $json.ctx.contact_id ?? '' ] }}
```

---

### Node 6 — `FN Decide Booking`  (Code)

```javascript
// FN Decide Booking — every reason NOT to place a hold, in order. Pure function.
const c = $input.first().json;

let refuse = null;
if (!c.tenant_id)                     refuse = ['unknown_tenant', 'Unknown clinic.'];
else if (c.tool_allowed !== true)     refuse = ['tool_not_allowed', 'This action is not available for this user.'];
else if (!c.contact)                  refuse = ['tool_not_allowed', 'Unknown patient.'];
else if (!c.service)                  refuse = ['service_unknown', 'That is not a service we offer.'];
else if (c.too_soon)                  refuse = ['lead_time_too_short', 'That time is too soon (or already past).'];
else if (Number(c.days_ahead) > Number(c.max_days_in_advance))
                                      refuse = ['too_far_ahead', `We book up to ${c.max_days_in_advance} days ahead.`];
else if (c.closed !== false)          refuse = ['clinic_closed', `The clinic is closed on ${c.day_label}.`];
else if (c.within_hours !== true)     refuse = ['slot_outside_hours', 'That time is outside opening hours.'];
else if (c.on_grid !== true)          refuse = ['slot_outside_hours', 'That is not a bookable start time.'];

return [{ json: { ...c, place: !refuse, refuse_reason: refuse?.[0] ?? null, refuse_summary: refuse?.[1] ?? null } }];
```

### Node 7 — `IF Place Hold`  (If)

`{{ $json.place }}` **Boolean → is true**. **true** → node 8. **false** → node 13
(`FN Booking Result`, built below; connect it once that node exists).

---

### Node 8 — `PG Place Hold`  (Postgres)

**The double-booking guard, live.**

```sql
WITH ins AS (
  INSERT INTO appointments
    (tenant_id, contact_id, service_id, service_code, start_time, end_time,
     status, hold_expires_at, source_channel, booked_by_role, notes)
  SELECT $1::uuid, $2::uuid, sv.id, sv.code,
         $3::timestamptz,
         $3::timestamptz + make_interval(mins => sv.duration_minutes),
         'held',
         now() + make_interval(mins => s.hold_ttl_minutes),
         $5::channel_t, $6::actor_role_t, $7
  FROM services sv
  JOIN clinic_settings s ON s.tenant_id = sv.tenant_id
  WHERE sv.tenant_id = $1::uuid AND sv.code = $4
  ON CONFLICT DO NOTHING            -- the no-overlap constraint says no → zero rows, not an error
  RETURNING id, start_time, end_time
)
SELECT (SELECT id FROM ins)                                                               AS appointment_id,
       (SELECT to_char(start_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') FROM ins) AS start_utc,
       (SELECT to_char(end_time   AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') FROM ins) AS end_utc;
```

**Query Parameters:**

```
{{ [ $json.tenant_id, $('FN Validate Tool Request').first().json.ctx.contact_id, $('FN Validate Tool Request').first().json.args.start_time, $('FN Validate Tool Request').first().json.args.service_code, $('FN Validate Tool Request').first().json.ctx.channel, $('FN Validate Tool Request').first().json.ctx.actor_role, 'corr ' + $('FN Validate Tool Request').first().json.ctx.correlation_id ] }}
```

### Node 9 — `IF Hold Placed`  (If)

`{{ !!$json.appointment_id }}` **Boolean → is true**. **true** → node 10.
**false** → node 13 (slot taken).

---

### Node 10 — `GC Create Event`  (Google Calendar)

| Setting | Value |
|---|---|
| Credential | `SalesFixr Google Calendar` |
| Resource / Operation | **Event** / **Create** |
| Calendar | **By ID**: `{{ $env.SF_GOOGLE_CALENDAR_ID }}` |
| Start | `{{ $json.start_utc }}` |
| End | `{{ $json.end_utc }}` |
| Additional Fields → Summary | `{{ $('PG Load Booking Context').first().json.service.display_name }} — {{ $('PG Load Booking Context').first().json.contact.name || 'New patient' }}` |
| Additional Fields → Description | `Booked by SalesFixr. Appointment {{ $json.appointment_id }}. Phone: {{ $('PG Load Booking Context').first().json.contact.phone || 'n/a' }}` |

**Settings:** On Error → **Continue**.

### Node 11 — `IF Event Created`  (If)

`{{ !!$json.id && $json.error === undefined }}` **Boolean → is true**.
**true** → node 12. **false** → node 13 (calendar failed; the hold expires by itself).

---

### Node 12 — `PG Confirm Booking`  (Postgres)

**Settings → Always Output Data: ON** (zero rows = the hold expired in the meantime).

```sql
WITH b AS (
  UPDATE appointments
     SET status = 'booked', calendar_event_id = $2, hold_expires_at = NULL
   WHERE id = $1::uuid AND status = 'held'
  RETURNING id, tenant_id, contact_id, service_code, start_time, end_time, source_channel
),
-- One reminder per offset in clinic_settings (24h and 2h by default), only if still in the future.
rem AS (
  INSERT INTO reminders (tenant_id, appointment_id, contact_id, offset_hours, send_at, channel)
  SELECT b.tenant_id, b.id, b.contact_id, o,
         b.start_time - make_interval(hours => o), b.source_channel
  FROM b
  JOIN clinic_settings s ON s.tenant_id = b.tenant_id
  CROSS JOIN LATERAL unnest(s.reminder_offsets_hours) AS o
  WHERE b.start_time - make_interval(hours => o) > now()
  ON CONFLICT (appointment_id, offset_hours) DO NOTHING
  RETURNING offset_hours
),
-- The offer that led here is now used up.
used AS (
  UPDATE booking_offers SET status = 'used'
   WHERE contact_id = (SELECT contact_id FROM b) AND status = 'open'
  RETURNING id
),
named AS (
  UPDATE contacts SET full_name = NULLIF($3, '')
   WHERE id = (SELECT contact_id FROM b) AND full_name IS NULL AND NULLIF($3, '') IS NOT NULL
  RETURNING id
)
SELECT b.id                                                                   AS appointment_id,
       to_char(b.start_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS start_time,
       to_char(b.end_time   AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS end_time,
       to_char(b.start_time AT TIME ZONE t.timezone, 'FMDay DD FMMonth')      AS day_label,
       to_char(b.start_time AT TIME ZONE t.timezone, 'FMHH12:MI AM')          AS time_label,
       sv.display_name                                                        AS service_display_name,
       COALESCE(c.full_name, NULLIF($3, ''))                                  AS patient_name,
       c.phone_e164                                                           AS patient_phone,
       b.source_channel                                                       AS channel,
       (SELECT array_agg(offset_hours ORDER BY offset_hours DESC) FROM rem)   AS reminder_offsets
FROM b
JOIN tenants  t  ON t.id = b.tenant_id
JOIN services sv ON sv.tenant_id = b.tenant_id AND sv.code = b.service_code
JOIN contacts c  ON c.id = b.contact_id;
```

**Query Parameters:**

```
{{ [ $('PG Place Hold').first().json.appointment_id, $json.id, $('FN Validate Tool Request').first().json.args.patient_name ] }}
```

`WHERE … status = 'held'` matters: if the hold expired and someone else's booking
released it in the meantime, this updates nothing, and the patient is told the
truth instead of being "confirmed" into a slot they no longer hold.

---

### Node 13 — `FN Booking Result`  (Code)

Connect **four** inputs into it: `IF Place Hold` (false), `IF Hold Placed`
(false), `IF Event Created` (false), and `PG Confirm Booking`.

```javascript
// FN Booking Result — one place that turns "which path ran" into the tool answer.
const req    = $('FN Validate Tool Request').first().json;
const ctx    = $('PG Load Booking Context').first().json;
const decide = $('FN Decide Booking').first().json;
const ran = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };

const hold   = ran('PG Place Hold')      ? $('PG Place Hold').first().json      : null;
const gc     = ran('GC Create Event')    ? $('GC Create Event').first().json    : null;
const booked = ran('PG Confirm Booking') ? $('PG Confirm Booking').first().json : null;

let ok = false, reason, summary, data = {};

if (!decide.place) {
  reason = decide.refuse_reason; summary = decide.refuse_summary;
} else if (!hold || !hold.appointment_id) {
  reason = 'slot_taken'; summary = 'That time was just taken.';
} else if (!gc || gc.error !== undefined || !gc.id) {
  reason = 'calendar_unavailable';
  summary = "The booking couldn't be added to the calendar, so nothing was booked.";
} else if (!booked || !booked.appointment_id) {
  reason = 'hold_expired'; summary = 'The hold expired before the booking was confirmed.';
} else {
  ok = true; reason = 'ok'; data = booked;
  summary = `Booked: ${booked.service_display_name}, ${booked.day_label} at ${booked.time_label}.`;
}

const telegram_text = ok ? [
  '🦷 New booking',
  `${booked.service_display_name}`,
  `${booked.day_label}, ${booked.time_label}`,
  `Patient: ${booked.patient_name || 'New patient'}${booked.patient_phone ? ' (' + booked.patient_phone + ')' : ''}`,
  `Channel: ${booked.channel} · Ref ${String(booked.appointment_id).slice(0, 8)}`,
].join('\n') : null;

return [{
  json: {
    booked: ok,
    telegram_text,
    response: { ok, reason_code: reason, data, human_summary: summary },
    audit: {
      tenant_id:      ctx.tenant_id ?? '',
      contact_id:     ctx.contact?.id ?? '',
      correlation_id: req.ctx.correlation_id,
      status:         ok ? 'ok' : 'blocked',
      reason_code:    reason,
      details: {
        actor_role: req.ctx.actor_role,
        args: req.args,
        appointment_id: booked?.appointment_id ?? hold?.appointment_id ?? null,
        calendar_event_id: gc?.id ?? null,
        reminders: booked?.reminder_offsets ?? null,
        holds_released: Number(ctx.holds_released ?? 0),
      },
    },
  },
}];
```

### Node 14 — `IF Booked`  (If)

`{{ $json.booked }}` **Boolean → is true**. **true** → node 15. **false** → node 16.

### Node 15 — `TG Notify Owner`  (Telegram)

| Setting | Value |
|---|---|
| Credential | `SalesFixr Telegram` |
| Chat ID | `{{ $('PG Load Booking Context').first().json.telegram_chat_id }}` |
| Text | `{{ $('FN Booking Result').first().json.telegram_text }}` |
| Additional Fields → Append n8n Attribution | off |

**Settings:** On Error → **Continue**. Connect → node 16.

### Node 16 — `PG Write Tool Audit`  (Postgres)

Same SQL as E, with the action name changed:

```sql
INSERT INTO audit_logs
  (tenant_id, contact_id, workflow, action, status, reason_code, correlation_id, details)
VALUES
  (NULLIF($1, '')::uuid, NULLIF($2, '')::uuid, 'TOOL', 'book_appointment', $3, $4, $5, $6::jsonb)
RETURNING id;
```

**Query Parameters**: read from `FN Booking Result` by name, because `$json` differs
depending on whether Telegram ran:

```
{{ [ $('FN Booking Result').first().json.audit.tenant_id, $('FN Booking Result').first().json.audit.contact_id, $('FN Booking Result').first().json.audit.status, $('FN Booking Result').first().json.audit.reason_code, $('FN Booking Result').first().json.audit.correlation_id, JSON.stringify($('FN Booking Result').first().json.audit.details) ] }}
```

### Node 17 — `RESP Tool Result`  (Respond to Webhook)

Respond With **JSON**, body:
`{{ JSON.stringify($('FN Booking Result').first().json.response) }}`

**Save → Publish.**

---

## F4. Tool — `SF TOOL escalate_to_human`

What the master plan called WF-06, built as a tool so voice can use it too: when a
patient needs a person, **the owner is alerted and the AI goes quiet on that
thread**, so it doesn't talk over the human who's about to reply. The pause is the
`ai_paused_until` column from Milestone B. The safety gate already blocks AI
replies while it's set.

Duplicate `SF TOOL check_availability` → **`SF TOOL escalate_to_human`**. Delete
nodes 5–9 of the copy.

### Node 1 — `WH Tool Escalate To Human`

Path: `salesfixr/v1/tool/escalate_to_human`.

### Node 2 — `FN Validate Tool Request`  (replace the code)

```javascript
// FN Validate Tool Request — escalate_to_human
const body = $input.first().json.body || {};
const auth = body.auth || {};
const ctx  = body.context || {};
const args = body.args || {};
const expected = String($env.SF_TOOL_TOKEN || '');

let gate = 'ok', problem = null;
if (expected.length < 16)                 { gate = 'unauthorized'; problem = 'Tool token is not configured on the server.'; }
else if (auth.tool_token !== expected)    { gate = 'unauthorized'; problem = 'Invalid tool token.'; }
else if ('contact_id' in args)            { gate = 'bad_request';  problem = 'contact_id is not accepted in args.'; }
else if (!ctx.correlation_id || !ctx.tenant_slug || !['customer', 'staff', 'owner'].includes(ctx.actor_role))
                                          { gate = 'bad_request';  problem = 'context needs correlation_id, tenant_slug and a valid actor_role.'; }
else if (ctx.actor_role === 'customer' && !ctx.contact_id)
                                          { gate = 'bad_request';  problem = 'context.contact_id is required for customers.'; }
else if (!args.summary || typeof args.summary !== 'string')
                                          { gate = 'bad_request';  problem = 'args.summary is required.'; }

return [{
  json: {
    gate, problem,
    ctx: {
      correlation_id: ctx.correlation_id ?? null,
      tenant_slug:    ctx.tenant_slug ?? null,
      actor_role:     ctx.actor_role ?? null,
      contact_id:     ctx.contact_id ?? null,
    },
    args: {
      summary: String(args.summary || '').slice(0, 500),
      urgency: args.urgency === 'urgent' ? 'urgent' : 'normal',
      pause_hours: 12,          // how long the AI stays quiet on this thread
    },
  },
}];
```

### Node 5 — `PG Escalate`  (Postgres, Always Output Data ON)

Pauses the AI **only for patients**. An owner asking for "a human" isn't paused out
of their own assistant.

```sql
WITH t AS (SELECT id FROM tenants WHERE slug = $1 AND is_active),
allowed AS (
  SELECT p.allowed_tools @> ARRAY['escalate_to_human'] AS ok
  FROM ai_personas p, t
  WHERE p.tenant_id = t.id AND p.role = $2::actor_role_t AND p.is_active
),
c AS (
  SELECT c.id, c.full_name, c.phone_e164 FROM contacts c, t
  WHERE c.id = NULLIF($3, '')::uuid AND c.tenant_id = t.id
),
paused AS (
  UPDATE contacts
     SET ai_paused_until = now() + make_interval(hours => $4::int)
   WHERE id = (SELECT id FROM c)
     AND $2::actor_role_t = 'customer'
     AND COALESCE((SELECT ok FROM allowed), false)
  RETURNING ai_paused_until
)
SELECT t.id                                                   AS tenant_id,
       COALESCE((SELECT ok FROM allowed), false)              AS tool_allowed,
       (SELECT id FROM c)                                     AS contact_id,
       (SELECT full_name FROM c)                              AS contact_name,
       (SELECT phone_e164 FROM c)                             AS contact_phone,
       (SELECT to_char(ai_paused_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') FROM paused) AS paused_until,
       (SELECT telegram_chat_id FROM clinic_settings WHERE tenant_id = t.id) AS telegram_chat_id,
       (SELECT ci.channel || ':' || ci.external_contact_id
          FROM contact_identities ci WHERE ci.contact_id = (SELECT id FROM c)
         ORDER BY ci.created_at DESC LIMIT 1)                 AS reach_via
FROM t;
```

**Query Parameters:**

```
{{ [ $json.ctx.tenant_slug, $json.ctx.actor_role, $json.ctx.contact_id ?? '', $json.args.pause_hours ] }}
```

### Node 6 — `IF Escalation Allowed`  (If)

`{{ !!$json.tenant_id && $json.tool_allowed === true && ($('FN Validate Tool Request').first().json.ctx.actor_role !== 'customer' || !!$json.contact_id) }}`
**Boolean → is true**. **true** → node 7. **false** → node 8.

### Node 7 — `TG Notify Owner Escalation`  (Telegram)

| Setting | Value |
|---|---|
| Chat ID | `{{ $json.telegram_chat_id }}` |
| Text | see below |
| Append n8n Attribution | off |

Text (Expression):

```
{{ $('FN Validate Tool Request').first().json.args.urgency === 'urgent' ? '🚨 URGENT: a patient needs a person' : '🙋 A patient asked for a person' }}
{{ $json.contact_name || 'Unknown name' }}{{ $json.contact_phone ? ' (' + $json.contact_phone + ')' : '' }}
Via: {{ $json.reach_via || 'n/a' }}
{{ $('FN Validate Tool Request').first().json.args.summary }}
{{ $json.paused_until ? 'AI paused on this thread for ' + $('FN Validate Tool Request').first().json.args.pause_hours + ' h.' : '' }}
```

**Settings:** On Error → **Continue**. Connect → node 8.

### Node 8 — `FN Escalation Result`  (Code)

Two inputs: `IF Escalation Allowed` (false) and `TG Notify Owner Escalation`.

```javascript
// FN Escalation Result
const req = $('FN Validate Tool Request').first().json;
const ctx = $('PG Escalate').first().json;
const ran = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };
const tg = ran('TG Notify Owner Escalation') ? $('TG Notify Owner Escalation').first().json : null;

let ok = false, reason, summary;
const alert_sent = !!tg && tg.error === undefined;

if (!ctx.tenant_id)                 { reason = 'unknown_tenant';   summary = 'Unknown clinic.'; }
else if (ctx.tool_allowed !== true) { reason = 'tool_not_allowed'; summary = 'Not available for this user.'; }
else if (!ran('TG Notify Owner Escalation')) { reason = 'tool_not_allowed'; summary = 'Unknown patient.'; }
else {
  ok = true;
  reason = req.args.urgency === 'urgent' ? 'escalated_medical' : 'escalated_requested';
  summary = alert_sent ? 'The team has been alerted.' : 'Escalation recorded, but the alert could not be sent.';
}

return [{
  json: {
    response: { ok, reason_code: reason, data: { alert_sent, paused_until: ctx.paused_until ?? null }, human_summary: summary },
    audit: {
      tenant_id: ctx.tenant_id ?? '', contact_id: ctx.contact_id ?? '',
      correlation_id: req.ctx.correlation_id,
      status: ok ? 'ok' : 'blocked', reason_code: reason,
      details: { actor_role: req.ctx.actor_role, urgency: req.args.urgency, alert_sent, paused_until: ctx.paused_until ?? null },
    },
  },
}];
```

### Nodes 9–10 — `PG Write Tool Audit` → `RESP Tool Result`

As in F3 nodes 16–17, with action `'escalate_to_human'` and every
`$('FN Booking Result')` replaced by `$('FN Escalation Result')`. (Here `$json`
would work too, since nothing sits between them, but keeping the same expressions
across all tools makes them easier to compare.)

**Save → Publish.**

---

## F5. Tool — `SF TOOL get_schedule`

Owner/staff only (the customer persona doesn't list it, so contract rule 2 refuses
patients automatically). This is what makes master-plan **step 6** work: the owner
asks about a day and gets the real list.

Duplicate `SF TOOL check_availability` → **`SF TOOL get_schedule`**. Delete nodes 5–9.

### Node 1 — path `salesfixr/v1/tool/get_schedule`

### Node 2 — `FN Validate Tool Request`  (replace the code)

```javascript
// FN Validate Tool Request — get_schedule
const body = $input.first().json.body || {};
const auth = body.auth || {}, ctx = body.context || {}, args = body.args || {};
const expected = String($env.SF_TOOL_TOKEN || '');
const isRealDate = (s) => /^\d{4}-\d{2}-\d{2}$/.test(s || '')
  && new Date(`${s}T00:00:00Z`).toISOString().slice(0, 10) === s;

let gate = 'ok', problem = null;
if (expected.length < 16)              { gate = 'unauthorized'; problem = 'Tool token is not configured on the server.'; }
else if (auth.tool_token !== expected) { gate = 'unauthorized'; problem = 'Invalid tool token.'; }
else if (!ctx.correlation_id || !ctx.tenant_slug || !['customer', 'staff', 'owner'].includes(ctx.actor_role))
                                       { gate = 'bad_request';  problem = 'context needs correlation_id, tenant_slug and a valid actor_role.'; }
else if (!isRealDate(args.date))       { gate = 'bad_request';  problem = 'args.date must be a real date, YYYY-MM-DD.'; }

return [{ json: { gate, problem,
  ctx: { correlation_id: ctx.correlation_id ?? null, tenant_slug: ctx.tenant_slug ?? null,
         actor_role: ctx.actor_role ?? null, contact_id: ctx.contact_id ?? null },
  args: { date: args.date ?? null } } }];
```

### Node 5 — `PG Load Schedule`  (Postgres, Always Output Data ON)

```sql
WITH t AS (SELECT id, timezone FROM tenants WHERE slug = $1 AND is_active)
SELECT
  t.id AS tenant_id,
  (SELECT p.allowed_tools @> ARRAY['get_schedule']
     FROM ai_personas p
    WHERE p.tenant_id = t.id AND p.role = $2::actor_role_t AND p.is_active) AS tool_allowed,
  to_char($3::date, 'FMDay DD FMMonth') AS day_label,
  (SELECT json_agg(json_build_object(
            'appointment_id', a.id,
            'time',    to_char(a.start_time AT TIME ZONE t.timezone, 'FMHH12:MI AM'),
            'service', COALESCE(sv.display_name, a.service_code),
            'patient', COALESCE(c.full_name, '(no name yet)'),
            'phone',   c.phone_e164,
            'status',  a.status) ORDER BY a.start_time)
     FROM appointments a
     JOIN contacts c ON c.id = a.contact_id
     LEFT JOIN services sv ON sv.tenant_id = a.tenant_id AND sv.code = a.service_code
    WHERE a.tenant_id = t.id
      AND a.status IN ('held', 'booked')
      AND (a.start_time AT TIME ZONE t.timezone)::date = $3::date) AS appointments
FROM t;
```

**Query Parameters:** `{{ [ $json.ctx.tenant_slug, $json.ctx.actor_role, $json.args.date ] }}`

### Node 6 — `FN Schedule Result`  (Code)

```javascript
// FN Schedule Result
const req = $('FN Validate Tool Request').first().json;
const c = $input.first().json;
const list = c.appointments || [];

let ok = false, reason, summary, data = {};
if (!c.tenant_id)                 { reason = 'unknown_tenant';   summary = 'Unknown clinic.'; }
else if (c.tool_allowed !== true) { reason = 'tool_not_allowed'; summary = 'Not available for this user.'; }
else {
  ok = true; reason = 'ok';
  data = { date: req.args.date, day_label: c.day_label, count: list.length, appointments: list };
  summary = `${list.length} appointment(s) on ${c.day_label}.`;
}

return [{ json: {
  response: { ok, reason_code: reason, data, human_summary: summary },
  audit: { tenant_id: c.tenant_id ?? '', contact_id: req.ctx.contact_id ?? '',
           correlation_id: req.ctx.correlation_id, status: ok ? 'ok' : 'blocked', reason_code: reason,
           details: { actor_role: req.ctx.actor_role, date: req.args.date, count: list.length } },
} }];
```

### Nodes 7–8 — `PG Write Tool Audit` → `RESP Tool Result`

As in E (action `'get_schedule'`, reading `$json.audit` / `$('FN Schedule Result')`).

**Save → Publish.**

---

## F6. Test the three tools by hand

Same PowerShell setup as E4.3 (`$toolToken` read from `.env`). Add this
general-purpose caller:

```powershell
function Invoke-Tool($name, $context, $toolArgs) {
  $context.correlation_id = "manual-f-" + (Get-Random)
  $context.tenant_slug = "demo_clinic"
  $payload = @{ auth = @{ tool_token = $toolToken }; context = $context; args = $toolArgs } | ConvertTo-Json -Depth 6
  try {
    Invoke-RestMethod -Method Post -ContentType "application/json" -Body $payload `
      -Uri "http://localhost:5678/webhook/salesfixr/v1/tool/$name" | ConvertTo-Json -Depth 8
  } catch { "HTTP $($_.Exception.Response.StatusCode.value__): " + $_.ErrorDetails.Message }
}
```

Get two patient ids and pick a test slot: a weekday 2+ days ahead, 11:00 New York
time. New York is UTC-4 until early November and UTC-5 after, so 11:00 New York is
`15:00Z` or `16:00Z`. Easiest is to let Postgres compute it:

```sql
SELECT id, phone_e164 FROM contacts WHERE phone_e164 IN ('+12125550199', '+15550000001');

SELECT to_char((((now() AT TIME ZONE 'America/New_York')::date + 2) + time '11:00')
               AT TIME ZONE 'America/New_York' AT TIME ZONE 'UTC',
               'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS slot_utc,
       to_char((now() AT TIME ZONE 'America/New_York')::date + 2, 'YYYY-MM-DD (FMDay)') AS day;
```

If that day is a Saturday or Sunday, use `+ 3` or `+ 4` instead.

```powershell
$patientA = "PASTE-ID-OF-+12125550199"
$ownerC   = "PASTE-ID-OF-+15550000001"
$slot     = "PASTE-slot_utc"
$day      = "PASTE-YYYY-MM-DD"
```

| # | Command | Expect |
|---|---|---|
| F-T1 | `Invoke-Tool book_appointment @{actor_role="customer"; contact_id=$patientA; channel="test"} @{service_code="dental_cleaning"; start_time=$slot; patient_name="Test Patient"}` | `ok: true`, `data.day_label`, `time_label: 11:00 AM`, `reminder_offsets: [24, 2]`. **A calendar event appears. Telegram pings.** |
| F-T2 | Same command again | `ok: false`, `slot_taken`. **Master-plan step 7: double booking refused, by Postgres** |
| F-T3 | Same, with `start_time` 15 minutes later (e.g. `…T15:15:00Z`) | `slot_outside_hours` ("not a bookable start time"). Off the 30-minute grid |
| F-T4 | `Invoke-Tool book_appointment @{actor_role="owner"; contact_id=$patientA} @{service_code="dental_cleaning"; start_time=$slot}` | `tool_not_allowed`: the owner persona can't book through this tool (yet) |
| F-T5 | `Invoke-Tool get_schedule @{actor_role="owner"} @{date=$day}` | `ok: true`, `count: 1`, the 11:00 AM booking with Test Patient's name and phone |
| F-T6 | `Invoke-Tool get_schedule @{actor_role="customer"; contact_id=$patientA} @{date=$day}` | `tool_not_allowed`. A patient can't read the schedule, however they ask |
| F-T7 | `Invoke-Tool escalate_to_human @{actor_role="customer"; contact_id=$patientA} @{summary="Test: patient asked for a person"; urgency="normal"}` | `ok: true`, `alert_sent: true`, `paused_until` ≈ 12 h from now. Telegram pings |

After F-T7 the test patient is **paused**. Release them before continuing:

```sql
UPDATE contacts SET ai_paused_until = NULL WHERE phone_e164 = '+12125550199';
```

Check the database state F-T1 left behind:

```sql
SELECT a.status, a.calendar_event_id IS NOT NULL AS has_event,
       (SELECT count(*) FROM reminders r WHERE r.appointment_id = a.id) AS reminders
FROM appointments a WHERE a.notes LIKE 'corr manual-f-%';
```

`booked | true | 2`.

**Clean up** the manual booking: delete its event in Google Calendar, then

```sql
UPDATE appointments SET status = 'cancelled', cancel_reason = 'F manual test'
WHERE notes LIKE 'corr manual-f-%';
```

---

## F7. Wire it into WF-02

Eight edits. Open **SF WF-02 AI Conversation**.

### F7.1 `PG Load AI Context`: load the pending offer

In the SQL, find the comment line `-- Last 6 messages of THIS thread…` and add this
block **directly above it**:

```sql
  -- The booking offer this patient is answering (Milestone F), if any.
  (SELECT json_build_object(
            'id',           o.id,
            'service_code', o.service_code,
            'date',         to_char(o.offer_date, 'YYYY-MM-DD'),
            'day_label',    o.day_label,
            'slots',        o.slots)
     FROM booking_offers o
    WHERE o.tenant_id = t.id AND o.contact_id = $2::uuid
      AND o.status = 'open' AND o.expires_at > now()
    ORDER BY o.created_at DESC
    LIMIT 1)                                               AS pending_offer,

```

### F7.2 `FN Build Prompt`: show the offer to the model

Find the line `lines.push('', '=== RECENT CONVERSATION ===');` and add **above** it:

```javascript
// Milestone F: the times we just offered, so "yes" / "the 1:30 one" can be understood.
if (ctx.pending_offer) {
  const o = ctx.pending_offer;
  lines.push('', '=== PENDING OFFER (times you just offered this person) ===');
  lines.push(`Service: ${o.service_code}   Day: ${o.day_label} = ${o.date}`);
  for (const s of o.slots || []) lines.push(`- ${s.label}  (preferred_time ${s.local})`);
  lines.push('If the person accepts one of these ("yes", "1:30 works", "the first one"), set intent to "booking"');
  lines.push('and fill service_code, date and preferred_time from this offer. Never invent a time that is not listed.');
}
```

### F7.3 `FN Plan Action`: the `book` route

Three small changes in the code:

**(a)** Right after the line `let reason = v.reason_code;` add:

```javascript
let chosen_slot = null, offer_id = null, other_slots = [];
```

**(b)** Replace the booking block: everything from the line
`} else if (v.intent === 'booking' && !tenantView) {` down to, **but not
including**, the line `} else if (v.intent === 'booking' || v.intent === 'reschedule' …`.
Put this in its place:

```javascript
} else if (v.intent === 'booking' && !tenantView) {
  const q = clarify();
  // Did they pick one of the slots we actually offered? Compared against the
  // stored offer, never against the model's memory of the conversation.
  const offer = ctx.pending_offer;
  const slot = (!q && offer && offer.service_code === v.service_code && offer.date === v.date)
    ? (offer.slots || []).find((s) => s.local === v.preferred_time)
    : null;
  if (q) {
    route = 'reply';
    [reason, reply] = q;
    source = 'template';
  } else if (slot) {
    route = 'book';
    reply = null; source = null;
    chosen_slot = slot;
    offer_id = offer.id;
    other_slots = (offer.slots || []).filter((s) => s.local !== slot.local);
  } else {
    route = 'check_availability';
    reply = null; source = null;
  }
```

**(c)** In the `return [{ json: { … } }]` at the bottom, add three lines next to
`contact_phone_public`:

```javascript
    chosen_slot,
    offer_id,
    other_slots,
```

### F7.4 `SW Route By Action`: add the `book` output

Add a 6th rule: `{{ $json.route }}` **is equal to** `book`, Rename Output → `book`.
The fallback (`unrouted`) moves to the last position. **Check that the `unrouted`
connector still goes to `FN Unrouted`**, since adding a rule can shift which line is
attached to which output.

### F7.5 Availability branch: save the offer

**(a)** In `FN Availability Reply`, inside the returned `json`, add one line under
`offered_slots`:

```javascript
    offer_day_label: d.day_label ?? null,
```

**(b)** Delete the connection `FN Availability Reply` → `FN Finalize Reply` and insert
two nodes:

**`PG Save Booking Offer`**  (Postgres)

```sql
WITH closed AS (
  -- A new offer replaces any older open one for this patient.
  UPDATE booking_offers SET status = 'expired'
   WHERE tenant_id = $1::uuid AND contact_id = $2::uuid AND status = 'open'
  RETURNING id
),
ins AS (
  INSERT INTO booking_offers (tenant_id, contact_id, service_code, offer_date, day_label, slots, correlation_id)
  SELECT $1::uuid, $2::uuid, $3, $4::date, $5, $6::jsonb, $7
  WHERE jsonb_array_length($6::jsonb) > 0
  RETURNING id
)
SELECT (SELECT id FROM ins) AS offer_id, (SELECT count(*) FROM closed) AS replaced;
```

**Query Parameters:**

```
{{ [ $('TRG Called By Workflow').first().json.tenant_id, $('TRG Called By Workflow').first().json.contact_id, $json.service_code ?? '', $json.date ?? '1970-01-01', $json.offer_day_label ?? '', JSON.stringify($json.offered_slots || []), $json.correlation_id ] }}
```

The `WHERE jsonb_array_length(…) > 0` means "fully booked" or an error saves no
offer. The query always returns exactly one row, so the branch never stops.

**`FN Merge Offer`**  (Code)

```javascript
// Bring the reply data back after the database step (a Postgres node replaces $json).
return [{ json: { ...$('FN Availability Reply').first().json, offer_id: $json.offer_id ?? null } }];
```

Wire: `FN Availability Reply` → `PG Save Booking Offer` → `FN Merge Offer` →
`FN Finalize Reply`.

### F7.6 The `book` branch

From the Switch's new `book` output:

```
SW Route By Action ─book→ FN Build Booking Request → HTTP Tool Book Appointment
                        → FN Booking Reply → FN Finalize Reply
```

**`FN Build Booking Request`**  (Code)

```javascript
// The slot comes from the stored offer (chosen_slot.start, a UTC instant from the
// availability tool), never from the model's text.
const p   = $input.first().json;
const req = $('TRG Called By Workflow').first().json;
const ctx = $('PG Load AI Context').first().json;
return [{ json: { ...p, tool_request: {
  auth: { tool_token: $env.SF_TOOL_TOKEN },
  context: {
    correlation_id: req.correlation_id, tenant_slug: ctx.tenant_slug,
    actor_role: req.actor_role, contact_id: req.contact_id,
    staff_user_id: req.staff_user_id || null, channel: req.channel,
  },
  // Name: what they said in this message, else what we already know about them.
  args: { service_code: p.service_code, start_time: p.chosen_slot.start, patient_name: p.patient_name || ctx.contact_name || '' },
} } }];
```

**`HTTP Tool Book Appointment`**: copy `HTTP Tool Check Availability` and change
the URL to `http://localhost:5678/webhook/salesfixr/v1/tool/book_appointment` and
the timeout to `30000` (calendar + Telegram take longer). Keep Never Error and On
Error → Continue.

**`FN Booking Reply`**  (Code)

```javascript
// FN Booking Reply — the confirmation is built from the tool's DATABASE ROW
// (data.day_label, data.time_label, data.service_display_name), never from the
// model's draft. Master plan rule 3: never confirm what you haven't done.
const res = $input.first().json;
const { tool_request, ...plan } = $('FN Build Booking Request').first().json;   // strip the token
const phone = plan.contact_phone_public;
const d = (res && res.data) || {};
const joinOr = (a) => (a.length <= 1 ? a.join('') : a.slice(0, -1).join(', ') + ' or ' + a[a.length - 1]);

let reply, status, reason;
if (!res || res.ok === undefined) {
  status = 'tool_error'; reason = 'calendar_unavailable';
  reply = `I couldn't complete the booking just now. Please call us on ${phone} and we'll get you booked in.`;
} else if (res.ok) {
  status = 'booked'; reason = 'ok';
  reply = `You're booked: ${d.service_display_name} on ${d.day_label} at ${d.time_label}. See you then!`;
} else if (res.reason_code === 'slot_taken') {
  status = 'slot_taken'; reason = 'slot_taken';
  const others = (plan.other_slots || []).map((s) => s.label);
  reply = others.length
    ? `Sorry, ${plan.chosen_slot.label} was just taken. ${joinOr(others)} ${others.length > 1 ? 'were' : 'was'} still open a moment ago. Would one of those work?`
    : `Sorry, ${plan.chosen_slot.label} was just taken. Would you like me to look for another time?`;
} else {
  status = 'failed'; reason = res.reason_code;
  reply = `I couldn't complete the booking just now. Please call us on ${phone} and we'll get you booked in.`;
}

return [{ json: { ...plan, action_status: status, reason_code: reason,
                  reply_text: reply, reply_source: 'template',
                  booked_appointment_id: d.appointment_id ?? null } }];
```

### F7.7 The `escalate` branch

Delete **`FN Stub Escalate`**. From the Switch's `escalate` output:

```
→ FN Build Escalation Request → HTTP Tool Escalate → FN Escalation Reply → FN Finalize Reply
```

**`FN Build Escalation Request`**  (Code)

```javascript
const p   = $input.first().json;
const req = $('TRG Called By Workflow').first().json;
const ctx = $('PG Load AI Context').first().json;
const urgent = p.intent === 'medical_question';
return [{ json: { ...p, tool_request: {
  auth: { tool_token: $env.SF_TOOL_TOKEN },
  context: { correlation_id: req.correlation_id, tenant_slug: ctx.tenant_slug,
             actor_role: req.actor_role, contact_id: req.contact_id },
  args: {
    summary: `${urgent ? 'Medical concern' : 'Asked for a person'}: "${String(req.message).slice(0, 300)}"`,
    urgency: urgent ? 'urgent' : 'normal',
  },
} } }];
```

**`HTTP Tool Escalate`**: copy the availability HTTP node, URL
`…/tool/escalate_to_human`, timeout `15000`.

**`FN Escalation Reply`**  (Code)

```javascript
// Says "I've let our team know" ONLY when the alert really went out.
const res = $input.first().json;
const { tool_request, ...plan } = $('FN Build Escalation Request').first().json;
const phone = plan.contact_phone_public;
const sent = !!(res && res.ok && res.data && res.data.alert_sent);
const medical = plan.intent === 'medical_question';

let reply;
if (medical) {
  reply = sent
    ? `I'm sorry you're dealing with that. I can't give medical advice over chat, but I've alerted our team and someone will contact you shortly. If it's severe or getting worse, please call us on ${phone} or seek emergency care.`
    : plan.reply_text;                       // C's fixed medical template
} else {
  reply = sent
    ? "Of course. I've let our team know, and someone will get back to you shortly."
    : `I'll need a member of our team for this. Please call us on ${phone}.`;
}

return [{ json: { ...plan,
  action_status: sent ? 'escalated' : 'escalation_failed',
  reason_code: medical ? 'escalated_medical' : 'escalated_requested',
  reply_text: reply, reply_source: 'template' } }];
```

After an escalation the patient's next messages are **blocked by the safety gate**
(`escalated_requested`) for 12 hours. That's intended: the human now owns the
thread. To hand it back to the AI early:

```sql
UPDATE contacts SET ai_paused_until = NULL WHERE id = 'PATIENT-CONTACT-ID';
```

### F7.8 The `owner_query` branch: schedule questions go to the tool

Keep `FN Stub Owner Query` (reports and contact lookups come later). Insert in
front of it:

```
SW Route By Action ─owner_query→ FN Build Schedule Request → IF Is Schedule Request
      ├─ true  → HTTP Tool Get Schedule → FN Schedule Reply → FN Finalize Reply
      └─ false → FN Stub Owner Query → FN Finalize Reply   (as before)
```

**`FN Build Schedule Request`**  (Code)

```javascript
const p   = $input.first().json;
const req = $('TRG Called By Workflow').first().json;
const ctx = $('PG Load AI Context').first().json;
if (p.intent !== 'owner_schedule') return [{ json: { ...p, is_schedule: false } }];
return [{ json: { ...p, is_schedule: true, tool_request: {
  auth: { tool_token: $env.SF_TOOL_TOKEN },
  context: { correlation_id: req.correlation_id, tenant_slug: ctx.tenant_slug,
             actor_role: req.actor_role, contact_id: req.contact_id },
  args: { date: p.date || ctx.local_today },     // "today" if no day was named
} } }];
```

**`IF Is Schedule Request`**: `{{ $json.is_schedule }}` **Boolean → is true**.

**`HTTP Tool Get Schedule`**: copy the availability HTTP node, URL
`…/tool/get_schedule`.

**`FN Schedule Reply`**  (Code)

```javascript
// Owner-style answer: lead with the number, one line per appointment. Every
// figure comes from the tool's rows (owner persona rule: never invent a number).
const res = $input.first().json;
const { tool_request, ...plan } = $('FN Build Schedule Request').first().json;
const ctx = $('PG Load AI Context').first().json;
const d = (res && res.data) || {};

let reply, status;
if (!res || !res.ok) {
  status = 'tool_error';
  reply = "I couldn't load the schedule just now.";
} else if (!d.count) {
  status = 'ok';
  reply = `${d.day_label}: no appointments.`;
} else {
  status = 'ok';
  const lines = d.appointments.map((a) =>
    `${a.time}  ${a.service}  ${a.patient}${a.phone ? ' (' + a.phone + ')' : ''}${a.status === 'held' ? ' [held]' : ''}`);
  reply = `${d.day_label}: ${d.count} appointment${d.count > 1 ? 's' : ''}\n` + lines.join('\n');
}
reply = reply.slice(0, Number(ctx.max_reply_chars) || 900);

return [{ json: { ...plan, action_status: status, reason_code: res?.ok ? 'ok' : (res?.reason_code || 'tool_error'),
                  reply_text: reply, reply_source: 'template' } }];
```

**Save → Publish WF-02.**

---

## F8. End-to-end acceptance: the master-plan demo

WF-01 Published (D3). Fresh test patients, so earlier tests and the rate limit
don't interfere. Replace `Monday` with a weekday 1–6 days ahead that's open until
18:00.

```powershell
$url = "http://localhost:5678/webhook/salesfixr/v1/inbound/test"
function Send-SF($phone, $msg) {
  $body = @{ channel = "test"; phone = $phone; message = $msg } | ConvertTo-Json
  $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -Body $body -TimeoutSec 90
  "{0,-18} {1,-22} {2}" -f $r.ai.route, $r.ai.action_status, $r.reply_text
}
$p1 = "+1212555" + (Get-Random -Minimum 1000 -Maximum 9999)
$p2 = "+1212555" + (Get-Random -Minimum 1000 -Maximum 9999)
$owner = "+15550000001"
```

| Step | Send | Expect |
|---|---|---|
| 1 | `Send-SF $p1 "Hi, can I book a cleaning on Monday at 10am?"` | `check_availability / slot_available`: "…10:00 AM on Monday … is free … Would you like me to book it?" |
| 2 | `Send-SF $p1 "Yes please. My name is Sara."` | `book / booked`: **"You're booked: Dental Cleaning on Monday 12 October at 10:00 AM. See you then!"** |
| 3 | *(look)* | Calendar event "Dental Cleaning — Sara" at 10:00. **Telegram:** 🦷 New booking … Sara |
| 4 | `Send-SF $p2 "Can I book a cleaning on Monday at 10am?"` | `alternatives_offered`: 10:00 is taken, three nearby times offered. **Step 7: no double booking** |
| 5 | `Send-SF $p2 "10:30 works"` | `book / booked` at **10:30 AM**, one of the offered slots |
| 6 | `Send-SF $owner "What does Monday look like?"` | `owner_query / ok`: "Monday 12 October: 2 appointments", 10:00 Sara, 10:30 … **Step 6: role-aware** |
| 7 | `Send-SF $p1 "What does Monday look like?"` | A patient asking the same thing gets **no** schedule (customer route, e.g. a clarifying question) |
| 8 | `Send-SF $p1 "Can I speak to a real person?"` | `escalate / escalated`: "I've let our team know…" + Telegram 🙋 |
| 9 | `Send-SF $p1 "hello?"` | Blank route and no reply: the safety gate blocked it (`escalated_requested`). The human owns the thread now |

Then the database:

```sql
-- The bookings
SELECT a.start_time AT TIME ZONE 'America/New_York' AS local_start, a.status,
       c.full_name, a.calendar_event_id IS NOT NULL AS on_calendar,
       (SELECT count(*) FROM reminders r WHERE r.appointment_id = a.id) AS reminders
FROM appointments a JOIN contacts c ON c.id = a.contact_id
WHERE a.created_at > now() - interval '1 hour' ORDER BY a.start_time;

-- Offers: each used exactly once
SELECT status, count(*) FROM booking_offers
WHERE created_at > now() - interval '1 hour' GROUP BY status;

-- One booking's full trail: TOOL book_appointment → WF-02 (route book) → WF-01
SELECT workflow, action, status, reason_code, details->>'route' AS route
FROM audit_logs
WHERE correlation_id = (SELECT correlation_id FROM audit_logs
                        WHERE action = 'book_appointment' AND status = 'ok' ORDER BY id DESC LIMIT 1)
ORDER BY id;
```

**Clean up:** release `$p1` (SQL above), cancel the test bookings, and delete their
calendar events:

```sql
UPDATE appointments SET status = 'cancelled', cancel_reason = 'F e2e test'
WHERE created_at > now() - interval '1 hour' AND status IN ('held', 'booked');
```

---

## F9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Yes please" gets a clarifying question ("Which service…?") | The model didn't fill the fields from the offer. Check `FN Build Prompt`'s `user_content` for the PENDING OFFER block. Missing → F7.1/F7.2 not done or WF-02 not re-published. Present → the offer expired (30 min) or a newer availability check replaced it |
| "Yes" triggers a *new* availability check instead of booking | The date/time/service the model returned doesn't exactly match the offer (e.g. `10:00` vs `10:30`). That's the intended safety behaviour; the patient gets a fresh, true answer |
| Booking says `calendar_unavailable` | GC Create failed: credential expired (7-day Testing limit, E1.2) or wrong calendar id. The hold expires by itself in 5 minutes |
| `tool_not_allowed` for a patient booking | The persona row lacks `book_appointment`. `SELECT allowed_tools FROM ai_personas WHERE role='customer';` |
| Booked, but no Telegram | `clinic_settings.telegram_chat_id` empty, you never messaged the bot first (§6 step 4), or wrong credential. The booking is still valid; that's the On Error → Continue design |
| Telegram message ends with "sent automatically with n8n" | *Append n8n Attribution* still on |
| `PG Place Hold` error `invalid input value for enum channel_t` | The context sent a channel the enum doesn't have. The validator maps unknown ones to `web`; check you replaced node 2's code |
| Two bookings in the same slot | Impossible if the `appointments_no_overlap` constraint exists: `SELECT conname FROM pg_constraint WHERE conname='appointments_no_overlap';`. If it's missing, fix that before anything else |
| Patient permanently silent after testing escalation | They're paused. `UPDATE contacts SET ai_paused_until = NULL WHERE …` |
| Owner's "what does Monday look like" gives the stub reply | F7.8 not done, or the model classified it as `owner_report`. Rephrase; or check `FN Build Schedule Request` sees `intent: owner_schedule` |
| The confirmation shows the wrong time | It can't come from the model. It's built from `PG Confirm Booking`'s row. Check `appointments.start_time` and the tenant timezone |

---

## Done when

- [ ] Telegram bot + credential; `clinic_settings.telegram_chat_id` set
- [ ] `db/005_booking_offers.sql` run
- [ ] `book_appointment`, `escalate_to_human`, `get_schedule` tools built and **Published**
- [ ] F-T1 … F-T7 pass by hand (F-T2 = double booking refused)
- [ ] WF-02: the eight F7 edits made, **Published**
- [ ] F8 steps 1–9 pass. That's the master-plan demo on the test channel
- [ ] No tool token anywhere in `conversations` / `audit_logs` (same check as E)
- [ ] Test bookings cleaned up; all workflows exported (3 new tools) and committed:

```powershell
cd F:\Agency\Automation_MVP
git add db docs workflows tests
git commit -m "Milestone F: booking end-to-end (hold, calendar, confirm, reminders), escalation, owner schedule"
git push
```

**Next:** Milestone G — the same flow, but from a real Facebook Page on your phone.
`docs/11-MILESTONE-G.md`.
