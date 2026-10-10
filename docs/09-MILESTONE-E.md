# Milestone E — Calendar + Availability

**Goal:** when a patient asks for a time, the system checks **real** availability
(the appointments in Postgres plus anything on the clinic's Google Calendar) and
answers truthfully: *"2:00 PM is free"* or *"2:00 PM is taken, the nearest free
times are 1:00, 1:30 and 2:30 PM."*

**Why now:** D gave every booking request a route. The `check_availability` branch
is still a placeholder that says "please call us". E replaces that placeholder with
the first real **tool**: a separate workflow at its own URL, built to the contract
in `docs/04-TOOL-API.md`, which the voice agent will call unchanged in Milestone I.

**Time:** about 2½ hours (30 minutes of it is Google setup).

**Prerequisite:** Milestone D green: the router script passes and WF-01, WF-02 and
WF-10 are all **Published**.

**Acceptance test (master plan):** ask for a taken slot → get 3 real alternatives.

---

## E0. What gets built

```
                    ┌──────────────────── SF TOOL check_availability  (new workflow) ──────────────────┐
WF-02 router        │ WH Tool Check Availability                                                     │
 check_availability │  → FN Validate Tool Request     token, required fields, no contact_id in args  │
 branch             │  → IF Request Accepted ── false ─→ RESP Tool Rejected (401 / 400)             │
  FN Build          │  → PG Load Availability Context  candidates + booked slots, ONE query          │
  Availability ─HTTP┼─→ GC Get Events For Day          busy times on the Google Calendar             │
  Request           │  → FN Compute Slots              free / taken / nearest 3                      │
  HTTP Tool Check   │  → PG Write Tool Audit                                                         │
  Availability ◄────┼─ RESP Tool Result                { ok, reason_code, data, human_summary }      │
  FN Availability   └──────────────────────────────────────────────────────────────────────────────┘
  Reply → FN Finalize Reply (from D)
```

**Why a separate workflow with its own URL, not more nodes inside WF-02:** the voice
agent (ElevenLabs, Milestone I) can only call HTTP URLs. If availability lived inside
WF-02, voice would need a second copy of it, and the two would drift apart. As a
tool at `/webhook/salesfixr/v1/tool/check_availability`, chat calls it today and
voice calls the same URL later. One brain, two mouths.

**Two sources of "busy", on purpose:**

| Source | What it catches | Why both |
|---|---|---|
| `appointments` table (status `held` or `booked`) | Every booking this system made | It's the source of truth; the no-double-booking constraint lives here |
| Google Calendar events | Anything staff put on the calendar by hand: a dentist's half-day off, a meeting, a manual booking | Real clinics already use a calendar. The bot must respect it, or it books over the dentist's lunch |

A slot is offered only if it's free in **both**.

---

## E1. Google Calendar setup  (≈30 minutes, once)

Most of this is in `docs/01-ACCOUNTS-AND-FREE-TIERS.md` §5. Do that section now,
with the extra notes below. Each one prevents a specific failure.

### E1.1 Create the clinic calendar

Google Calendar → left sidebar **Other calendars → + → Create new calendar**.
Name: `SalesFixr — SmileCare Dental`. **Time zone: (GMT-04:00) Eastern Time - New
York.** The demo clinic is in New York; if the calendar is in Dhaka time, every test
event you create by hand will be 10 hours off from what you meant.

Open the calendar's **Settings → Integrate calendar** and copy the **Calendar ID**
(`…@group.calendar.google.com`).

### E1.2 Google Cloud OAuth (doc 01 §5, steps 1–4)

Follow doc 01 §5 exactly. Extra notes:

- **Redirect URI.** In n8n, start creating the credential first (E1.3). The dialog
  shows an *OAuth Redirect URL*. Copy that exact value into Google Cloud. With your
  `.env` it will be `http://localhost:5678/rest/oauth2-credential/callback`.
- **Add yourself as a Test user** on the consent screen. Skipping this gives
  `Error 403: access_denied` when you click *Connect* in n8n.
- **The 7-day catch.** While the consent screen's *Publishing status* is
  **Testing**, Google expires the connection's refresh token after **7 days**. Then
  every availability check fails with `calendar_unavailable` until you reconnect.
  Two options:
  - Keep **Testing** and click *Reconnect* on the n8n credential once a week. Fine
    for building.
  - Click **Publish app** (consent screen → *Publishing status* → *In production*).
    For your own account you don't need Google's verification. You'll see an
    "unverified app" warning once when connecting (click *Advanced → Go to
    SalesFixr*). The token then stops expiring. **Do this before any client demo.**

### E1.3 The n8n credential

n8n → **Credentials → Create credential →** search **Google Calendar OAuth2 API**.

| Field | Value |
|---|---|
| Credential name | `SalesFixr Google Calendar` |
| Client ID | from Google Cloud |
| Client Secret | from Google Cloud |

Click **Sign in with Google** → choose your account → allow. It must show
**Connected** (green).

### E1.4 Put the calendar id and tool token where n8n can read them

In `infra/.env`:

```
SF_GOOGLE_CALENDAR_ID=paste-the-id@group.calendar.google.com
```

Check that `SF_TOOL_TOKEN=` is a long random string (you set it in Milestone A).
The tool rejects every call if it's shorter than 16 characters.

Apply:

```powershell
cd F:\Agency\Automation_MVP\infra
docker compose up -d
```

Both values reach n8n through `docker-compose.yml`, which already passes
`SF_GOOGLE_CALENDAR_ID` and `SF_TOOL_TOKEN` into the container.

### E1.5 New reason codes

No new tables in E. The new reason codes are listed in
`docs/02-NAMING-CONVENTIONS.md` §7: `unauthorized`, `bad_request`,
`too_far_ahead`, `clinic_closed`, `no_slots`, `calendar_unavailable`.

---

## E2. New things in this milestone — read once

### Google Calendar node — we name it `GC …`

*Node picker → **Google Calendar**.* Talks to Google with the OAuth credential from
E1.3. We use **Event → Get Many**: "give me every event between two moments".

Two settings matter more than they look:

- **After / Before:** the time window. We pass them as UTC instants
  (`2026-10-08T04:00:00Z`), computed by Postgres from the clinic's timezone. Never
  build them from your PC's clock: your PC is in Dhaka, the clinic is in New York.
- **Recurring events:** a weekly "Staff meeting, Tuesdays 1 PM" is one event with
  a repeat rule. Unless the node is told to expand repeats into individual
  occurrences, a repeating event created last month doesn't appear in today's window.

### "Always Output Data" — node Settings tab

When a node returns **zero items**, n8n stops that branch: the next node never
runs. An empty calendar day is normal, and so is an unknown clinic slug returning no
database row. **Always Output Data** makes the node emit one empty item instead, so
the next node runs and can *decide* what empty means. You'll turn it on for the
Postgres and Google Calendar nodes in the tool.

### Production webhook URL = must be Published

The tool is called at `/webhook/…` (production), never `/webhook-test/…`. That URL
exists **only while the workflow is Published**, and it runs the **published
version**. So: build, Save, **Publish**, and re-publish after every change. Same
rule as C4.

---

## E3. Build the tool — `SF TOOL check_availability`

New workflow. Name: **`SF TOOL check_availability`**. Tags: `salesfixr`, `tool`.

---

### Node 1 — `WH Tool Check Availability`  (Webhook)

| Setting | Value |
|---|---|
| HTTP Method | `POST` |
| Path | `salesfixr/v1/tool/check_availability` |
| Authentication | None. The token is checked in node 2, as the tool contract says |
| Respond | **Using 'Respond to Webhook' Node** |

---

### Node 2 — `FN Validate Tool Request`  (Code)

Rules 1 and 4 of the tool contract: **check the token first**, and **never accept
`contact_id` inside `args`**.

```javascript
// FN Validate Tool Request
// Tool contract rules 1 and 4 (docs/04-TOOL-API.md). Runs before ANY database work.

const body = $input.first().json.body || {};
const auth = body.auth || {};
const ctx  = body.context || {};
const args = body.args || {};
const expected = String($env.SF_TOOL_TOKEN || '');

let gate = 'ok';
let problem = null;

const isRealDate = (s) => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s || '')) return false;
  const ms = Date.parse(`${s}T00:00:00Z`);
  return !isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === s;   // rejects 2026-02-30
};

if (expected.length < 16) {
  gate = 'unauthorized'; problem = 'Tool token is not configured on the server.';
} else if (auth.tool_token !== expected) {
  gate = 'unauthorized'; problem = 'Invalid tool token.';
} else if ('contact_id' in args) {
  // Rule 4: the contact comes from the authenticated context, never from arguments
  // the AI could have filled in. This is what stops patient A reading patient B.
  gate = 'bad_request'; problem = 'contact_id is not accepted in args.';
} else if (!ctx.correlation_id || !ctx.tenant_slug || !['customer', 'staff', 'owner'].includes(ctx.actor_role)) {
  gate = 'bad_request'; problem = 'context needs correlation_id, tenant_slug and a valid actor_role.';
} else if (ctx.actor_role === 'customer' && !ctx.contact_id) {
  gate = 'bad_request'; problem = 'context.contact_id is required for customers.';
} else if (!args.service_code) {
  gate = 'bad_request'; problem = 'args.service_code is required.';
} else if (!isRealDate(args.date)) {
  gate = 'bad_request'; problem = 'args.date must be a real date, YYYY-MM-DD.';
} else if (args.preferred_time && !/^([01]\d|2[0-3]):[0-5]\d$/.test(args.preferred_time)) {
  gate = 'bad_request'; problem = 'args.preferred_time must be HH:MM (24h).';
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
    },
    args: {
      service_code:   args.service_code ?? null,
      date:           args.date ?? null,
      preferred_time: args.preferred_time || null,
    },
  },
}];
```

---

### Node 3 — `IF Request Accepted`  (If)

| Setting | Value |
|---|---|
| Condition | `{{ $json.gate }}` **String → is equal to** `ok` |

- **true** → node 5
- **false** → node 4

---

### Node 4 — `RESP Tool Rejected`  (Respond to Webhook)

| Setting | Value |
|---|---|
| Respond With | **JSON** |
| Response Body | `{{ JSON.stringify({ ok: false, reason_code: $json.gate, data: {}, human_summary: $json.problem }) }}` |
| Options → Response Code | Expression: `{{ $json.gate === 'unauthorized' ? 401 : 400 }}` |

A bad token gets **401**, a malformed request **400**. Both still use the standard
response shape, so the caller never has to guess.

---

### Node 5 — `PG Load Availability Context`  (Postgres, Execute Query)

Credential: `Postgres account`. **Settings → Always Output Data: ON.**

One query produces everything: the persona permission check (contract rule 2), the
service, that day's opening hours, and **every candidate start time** with whether
the database already has it booked.

```sql
WITH t AS (
  SELECT id, timezone FROM tenants WHERE slug = $1 AND is_active
),
s AS (
  SELECT cs.* FROM clinic_settings cs JOIN t ON cs.tenant_id = t.id
),
sv AS (
  SELECT sv.code, sv.display_name, sv.duration_minutes
  FROM services sv JOIN t ON sv.tenant_id = t.id
  WHERE sv.code = $2 AND sv.is_active
),
bh AS (
  SELECT bh.* FROM business_hours bh JOIN t ON bh.tenant_id = t.id
  WHERE bh.weekday = EXTRACT(DOW FROM $3::date)
),
-- Every possible start time that day, on the clinic's slot grid, such that the
-- whole appointment fits before closing. Built in LOCAL time, then converted to
-- real instants with AT TIME ZONE, so DST changes are handled by Postgres.
cand AS (
  SELECT gs                                                               AS local_start,
         gs AT TIME ZONE t.timezone                                       AS start_at,
         (gs + make_interval(mins => sv.duration_minutes)) AT TIME ZONE t.timezone AS end_at
  FROM t, s, sv, bh,
       generate_series($3::date + bh.opens_at,
                       $3::date + bh.closes_at - make_interval(mins => sv.duration_minutes),
                       make_interval(mins => s.slot_granularity_minutes)) AS gs
  WHERE NOT bh.is_closed
)
SELECT
  t.id                                                   AS tenant_id,
  t.timezone,
  -- Contract rule 2: re-check the role against the persona's allowed tools.
  (SELECT p.allowed_tools @> ARRAY['check_availability']
     FROM ai_personas p
    WHERE p.tenant_id = t.id AND p.role = $4::actor_role_t AND p.is_active) AS tool_allowed,
  EXISTS (SELECT 1 FROM contacts c
           WHERE c.id = NULLIF($5, '')::uuid AND c.tenant_id = t.id)      AS contact_ok,
  (SELECT row_to_json(x) FROM sv x)                                       AS service,
  (SELECT json_build_object('opens',  to_char(opens_at,  'HH24:MI'),
                            'closes', to_char(closes_at, 'HH24:MI'),
                            'closed', is_closed) FROM bh)                 AS hours,
  ($3::date - (now() AT TIME ZONE t.timezone)::date)                      AS days_ahead,
  s.max_days_in_advance,
  s.min_lead_time_minutes,
  to_char($3::date, 'FMDay DD FMMonth')                                   AS day_label,
  to_char(($3::date)::timestamp AT TIME ZONE t.timezone AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS"Z"')                                    AS day_start_utc,
  to_char(($3::date + 1)::timestamp AT TIME ZONE t.timezone AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS"Z"')                                    AS day_end_utc,
  (SELECT json_agg(json_build_object(
            'local',    to_char(c.local_start, 'HH24:MI'),
            'start',    to_char(c.start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            'end',      to_char(c.end_at   AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            'too_soon', c.start_at < now() + make_interval(mins => s.min_lead_time_minutes),
            -- Same rule as the no-double-booking constraint in 001_schema.sql:
            -- any 'held' or 'booked' appointment overlapping this slot makes it taken.
            'taken',    EXISTS (SELECT 1 FROM appointments a
                                 WHERE a.tenant_id = t.id
                                   AND a.status IN ('held', 'booked')
                                   AND tstzrange(a.start_time, a.end_time, '[)')
                                    && tstzrange(c.start_at, c.end_at, '[)'))
          ) ORDER BY c.local_start)
     FROM cand c)                                                          AS candidates
FROM t, s;
```

**Query Parameters** (array form, Expression mode):

```
{{ [ $json.ctx.tenant_slug, $json.args.service_code, $json.args.date, $json.ctx.actor_role, $json.ctx.contact_id ?? '' ] }}
```

Things worth understanding:

- **Why availability is computed in SQL, not JavaScript.** "2 PM on 8 October in
  New York" is a different instant in summer and winter. Postgres's `AT TIME ZONE`
  knows every daylight-saving rule. Hand-written JavaScript date maths is where
  booking systems get their "one hour off twice a year" bugs.
- **"Taken" uses exactly the rule of the `appointments_no_overlap` constraint**
  (`held` or `booked`, half-open ranges `[)`). If availability and the constraint
  ever disagreed, the bot would offer slots that the database then refuses in F.
  Same rule, written twice, on purpose.
- **Half-open ranges `[)`** mean a 13:30–14:00 cleaning and a 14:00 appointment
  don't overlap. Back-to-back bookings are allowed; overlapping ones aren't.
- **Fails closed:** unknown clinic → zero rows → (Always Output Data) one empty item
  → node 7 answers `unknown_tenant`. A role without the tool → `tool_allowed` false
  → `tool_not_allowed`.

---

### Node 6 — `GC Get Events For Day`  (Google Calendar)

| Setting | Value |
|---|---|
| Credential | `SalesFixr Google Calendar` |
| Resource | **Event** |
| Operation | **Get Many** |
| Calendar | switch the selector to **By ID**, Expression: `{{ $env.SF_GOOGLE_CALENDAR_ID }}` |
| Return All | **on** |
| After | Expression: `{{ $('PG Load Availability Context').first().json.day_start_utc }}` |
| Before | Expression: `{{ $('PG Load Availability Context').first().json.day_end_utc }}` |
| Recurring event handling (*Options*, name varies by n8n version) | **All occurrences** / expand recurring events |

**Settings tab:**

| Setting | Value | Why |
|---|---|---|
| Always Output Data | **on** | An empty day is normal. Without this, an empty calendar stops the workflow |
| On Error | **Continue** | If Google is unreachable, node 7 answers `calendar_unavailable` instead of crashing |

(In some versions *After* and *Before* sit under **Options → Add option**. Same
values either way.)

---

### Node 7 — `FN Compute Slots`  (Code)

```javascript
// FN Compute Slots
// Combines the database candidates with the Google Calendar busy times and
// produces the tool's response, in the standard contract shape.
// Fails CLOSED: if anything can't be verified, no slot is offered.

const req    = $('FN Validate Tool Request').first().json;
const ctx    = $('PG Load Availability Context').first().json;
const events = $('GC Get Events For Day').all().map((i) => i.json);
const args   = req.args;

const toMin = (hhmm) => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3, 5));
const to12h = (hhmm) => {
  let [h, m] = hhmm.split(':').map(Number);
  const ap = h >= 12 ? 'PM' : 'AM';
  h = h % 12 || 12;
  return `${h}:${String(m).padStart(2, '0')} ${ap}`;
};

let busy = [];
function done(ok, reason_code, data, human_summary) {
  return [{
    json: {
      response: { ok, reason_code, data, human_summary },
      audit: {
        tenant_id:      ctx.tenant_id ?? '',
        contact_id:     ctx.contact_ok ? (req.ctx.contact_id ?? '') : '',
        correlation_id: req.ctx.correlation_id,
        status:         ok ? 'ok' : 'blocked',
        reason_code,
        details: {
          actor_role: req.ctx.actor_role,
          args,
          requested_available: data.requested_available ?? null,
          offered: (data.slots || []).map((s) => s.local),
          free_count: data.free_count ?? null,
          calendar_busy_blocks: busy.length,
        },
      },
    },
  }];
}

// ---- refusals, in order --------------------------------------------------
if (!ctx.tenant_id)            return done(false, 'unknown_tenant', {}, 'Unknown clinic.');
if (ctx.tool_allowed !== true) return done(false, 'tool_not_allowed', {}, 'This action is not available for this user.');
if (req.ctx.actor_role === 'customer' && !ctx.contact_ok)
                               return done(false, 'tool_not_allowed', {}, 'Unknown patient.');
if (!ctx.service)              return done(false, 'service_unknown', {}, `"${args.service_code}" is not a service we offer.`);

const base = {
  service_code: ctx.service.code,
  service_name: ctx.service.display_name,
  duration_minutes: ctx.service.duration_minutes,
  date: args.date,
  day_label: ctx.day_label,
  requested_time: args.preferred_time,
};

if (Number(ctx.days_ahead) < 0)
  return done(false, 'past_date', base, 'That date has already passed.');
if (Number(ctx.days_ahead) > Number(ctx.max_days_in_advance))
  return done(false, 'too_far_ahead', base, `We book up to ${ctx.max_days_in_advance} days ahead.`);
if (!ctx.hours || ctx.hours.closed)
  return done(false, 'clinic_closed', base, `The clinic is closed on ${ctx.day_label}.`);

// ---- Google Calendar busy blocks -----------------------------------------
if (events.some((e) => e.error !== undefined))
  return done(false, 'calendar_unavailable', base, "The calendar couldn't be checked right now.");

const dayStart = Date.parse(ctx.day_start_utc);
const dayEnd   = Date.parse(ctx.day_end_utc);
busy = events
  .filter((e) => e.start && e.status !== 'cancelled' && e.transparency !== 'transparent')
  .map((e) => e.start.dateTime
    ? [Date.parse(e.start.dateTime), Date.parse(e.end.dateTime)]
    : [dayStart, dayEnd]);                       // all-day event = whole day busy

// ---- classify every candidate --------------------------------------------
const cands = (ctx.candidates || []).map((c) => {
  const s = Date.parse(c.start);
  const e = Date.parse(c.end);
  const calendarBusy = busy.some(([bs, be]) => s < be && e > bs);
  return { ...c, calendar_busy: calendarBusy, free: !c.taken && !c.too_soon && !calendarBusy, label: to12h(c.local) };
});
const free = cands.filter((c) => c.free);

const pref = args.preferred_time;
const requested = pref ? cands.find((c) => c.local === pref) : null;
const requested_available = !!(requested && requested.free);

// ---- why the requested time isn't available ------------------------------
let reason = 'ok';
if (pref && !requested_available) {
  if (!requested) {
    const outside = toMin(pref) < toMin(ctx.hours.opens)
                 || toMin(pref) + Number(ctx.service.duration_minutes) > toMin(ctx.hours.closes);
    reason = outside ? 'slot_outside_hours' : 'slot_taken';   // inside hours but off the 30-min grid
  } else if (requested.too_soon) {
    reason = 'lead_time_too_short';
  } else {
    reason = 'slot_taken';
  }
}
if (!free.length) reason = 'no_slots';

// ---- what to offer: the requested slot, or the 3 nearest free ones -------
let offered;
if (requested_available) {
  offered = [requested];
} else if (pref) {
  offered = [...free]
    .sort((a, b) => Math.abs(toMin(a.local) - toMin(pref)) - Math.abs(toMin(b.local) - toMin(pref))
                 || toMin(a.local) - toMin(b.local))
    .slice(0, 3)
    .sort((a, b) => toMin(a.local) - toMin(b.local));
} else {
  offered = free.slice(0, 3);
}
const slots = offered.map((c) => ({ start: c.start, end: c.end, local: c.local, label: c.label }));
const data = { ...base, requested_available, slots, free_count: free.length };

const labels = slots.map((s) => s.label).join(', ');
let summary;
if (requested_available)  summary = `${to12h(pref)} on ${ctx.day_label} is free.`;
else if (!slots.length)   summary = `No free times on ${ctx.day_label}.`;
else if (pref)            summary = `${to12h(pref)} on ${ctx.day_label} is not available. Nearest free times: ${labels}.`;
else                      summary = `Free times on ${ctx.day_label}: ${labels}.`;

return done(true, reason, data, summary);
```

**Why `ok: true` even when the time is taken:** the tool worked. It checked and
has an answer. `ok: false` is reserved for "couldn't check" or "not allowed to
check". "Taken" is information, carried by `reason_code: slot_taken` and
`requested_available: false`.

**Why "nearest three", re-sorted by time:** "2 PM is taken" → offering 1:30, 2:30
and 1:00 is more useful than 8:00, 8:30 and 9:00. They're then listed in clock
order, because "1:00, 1:30 or 2:30" reads naturally and "1:30, 2:30, 1:00" doesn't.

---

### Node 8 — `PG Write Tool Audit`  (Postgres, Execute Query)

Contract rule 5: every tool call leaves a row, tied to the conversation by
`correlation_id`.

```sql
INSERT INTO audit_logs
  (tenant_id, contact_id, workflow, action, status, reason_code, correlation_id, details)
VALUES
  (NULLIF($1, '')::uuid, NULLIF($2, '')::uuid, 'TOOL', 'check_availability', $3, $4, $5, $6::jsonb)
RETURNING id;
```

**Query Parameters:**

```
{{ [ $json.audit.tenant_id, $json.audit.contact_id, $json.audit.status, $json.audit.reason_code, $json.audit.correlation_id, JSON.stringify($json.audit.details) ] }}
```

---

### Node 9 — `RESP Tool Result`  (Respond to Webhook)

| Setting | Value |
|---|---|
| Respond With | **JSON** |
| Response Body | `{{ JSON.stringify($('FN Compute Slots').first().json.response) }}` |

Response code stays the default 200, including for `ok: false` answers (contract
rule 6: return `ok:false` rather than throwing).

### Wire and publish

```
WH Tool Check Availability → FN Validate Tool Request → IF Request Accepted
   ├─ false → RESP Tool Rejected
   └─ true  → PG Load Availability Context → GC Get Events For Day
             → FN Compute Slots → PG Write Tool Audit → RESP Tool Result
```

**Save → Publish.**

---

## E4. Test the tool on its own, before the AI touches it

`docs/04-TOOL-API.md` ends with the rule: test every tool by hand before wiring it
to the AI. When the AI misbehaves later, you'll already know the tool is right.

### E4.1 Create a known "taken" slot

Run in the Neon SQL Editor. It picks the **next weekday the clinic is open past
3 PM** (so it never lands on a Sunday or a short Saturday), books a cleaning there
at 2:00 PM, and prints the date to use in every test below.

```sql
WITH t AS (SELECT id, timezone FROM tenants WHERE slug = 'demo_clinic'),
d AS (
  SELECT min(g.day)::date AS day
  FROM t
  CROSS JOIN generate_series((now() AT TIME ZONE t.timezone)::date + 1,
                             (now() AT TIME ZONE t.timezone)::date + 7,
                             interval '1 day') AS g(day)
  JOIN business_hours bh
    ON bh.tenant_id = t.id AND bh.weekday = EXTRACT(DOW FROM g.day)
   AND NOT bh.is_closed AND bh.closes_at >= '15:00'
)
INSERT INTO appointments
  (tenant_id, contact_id, service_code, start_time, end_time, status, source_channel, booked_by_role, notes)
SELECT t.id, c.id, 'dental_cleaning',
       (d.day + time '14:00') AT TIME ZONE t.timezone,
       (d.day + time '14:30') AT TIME ZONE t.timezone,
       'booked', 'test', 'owner', 'E-TEST'
FROM t, d, contacts c
WHERE c.tenant_id = t.id AND c.phone_e164 = '+15550000001'
RETURNING to_char(start_time AT TIME ZONE 'America/New_York', 'YYYY-MM-DD (FMDay) HH24:MI') AS taken_slot;
```

Note the date it prints, e.g. `2026-10-12 (Monday) 14:00`. That's your **test day**.

### E4.2 Block an hour on Google Calendar

In the `SalesFixr — SmileCare Dental` calendar, create an event on your **test day**
from **4:00 PM to 5:00 PM** (New York time, which is the calendar's own timezone
from E1.1). Title it `Dentist out`.

### E4.3 The test function

Paste into PowerShell. It reads the tool token from your `.env`, so the token
never ends up in your shell history or a screenshot.

```powershell
$envFile = "F:\Agency\Automation_MVP\infra\.env"
$toolToken = ((Get-Content $envFile) | Where-Object { $_ -match '^SF_TOOL_TOKEN=' }) -replace '^SF_TOOL_TOKEN=', ''
$toolUrl = "http://localhost:5678/webhook/salesfixr/v1/tool/check_availability"

function Test-Avail($date, $time, $role = "customer", $contact = $null, $token = $toolToken, $service = "dental_cleaning") {
  $payload = @{
    auth    = @{ tool_token = $token }
    context = @{ correlation_id = "manual-e-" + (Get-Random); tenant_slug = "demo_clinic"; actor_role = $role; contact_id = $contact }
    args    = @{ service_code = $service; date = $date; preferred_time = $time }
  } | ConvertTo-Json -Depth 6
  try {
    Invoke-RestMethod -Method Post -Uri $toolUrl -ContentType "application/json" -Body $payload | ConvertTo-Json -Depth 6
  } catch {
    "HTTP $($_.Exception.Response.StatusCode.value__): " + $_.ErrorDetails.Message
  }
}
```

Get the test patient's contact id:

```sql
SELECT id FROM contacts WHERE phone_e164 = '+12125550199';
```

```powershell
$pid_ = "PASTE-CONTACT-ID"
$day  = "PASTE-TEST-DAY"          # e.g. 2026-10-12
```

### E4.4 The tool tests

| # | Command | Expect |
|---|---|---|
| T1 | `Test-Avail $day "10:00" "customer" $pid_` | `ok: true`, `reason_code: ok`, `requested_available: true`, one slot `10:00 AM` |
| T2 | `Test-Avail $day "14:00" "customer" $pid_` | `ok: true`, `reason_code: slot_taken`, **3 slots**: 1:00 PM, 1:30 PM, 2:30 PM ← **the acceptance test** |
| T3 | `Test-Avail $day "16:00" "customer" $pid_` | `slot_taken`. The **calendar** blocked it. Offered slots skip 4:00 and 4:30 |
| T4 | `Test-Avail $day "14:00" "customer" $pid_ "wrong-token-123456"` | `HTTP 401`, `reason_code: unauthorized` |
| T5 | `Test-Avail $day "14:00" "owner"` | `ok: false`, `tool_not_allowed`. The owner persona doesn't list this tool (contract rule 2, enforced) |
| T6 | `Test-Avail $day "14:00" "customer" $pid_ "$toolToken" "root_canal_deluxe"` | `ok: false`, `service_unknown` |
| T7 | Pick the next **Sunday** as the date | `ok: false`, `clinic_closed` |
| T8 | `Test-Avail $day "19:00" "customer" $pid_` | `slot_outside_hours`, nearest slots before closing |

T2 is the master-plan acceptance test. If it shows exactly three nearby times and
none of them is 2:00 PM, the core of E works.

**Check T3 carefully.** If 4:00 PM shows as free, the calendar isn't being read.
See the troubleshooting table.

Each call left an audit row:

```sql
SELECT created_at, status, reason_code, details->>'offered' AS offered, details->>'calendar_busy_blocks' AS cal
FROM audit_logs WHERE workflow = 'TOOL' ORDER BY id DESC LIMIT 10;
```

---

## E5. Wire the tool into the router (WF-02)

Open **SF WF-02 AI Conversation**.

### E5.1 Give the router the clinic's slug

The tool identifies the clinic by `tenant_slug` (that's the contract, and what
voice will send). WF-02 only has the id so far. In **`PG Load AI Context`**, make two
small edits to the SQL:

1. First line of the `t` CTE: change
   `SELECT id, timezone, (now() AT TIME ZONE timezone) AS local_now`
   to
   `SELECT id, slug, timezone, (now() AT TIME ZONE timezone) AS local_now`
2. In the main `SELECT`, right after `t.timezone AS tenant_timezone,` add the line
   `t.slug AS tenant_slug,`

### E5.2 Replace the stub

Delete **`FN Stub Check Availability`**. In its place, between the Switch's
`check_availability` output and `FN Finalize Reply`, build these three nodes:

```
SW Route By Action ─check_availability→ FN Build Availability Request
                                       → HTTP Tool Check Availability
                                       → FN Availability Reply → FN Finalize Reply
```

---

#### `FN Build Availability Request`  (Code)

```javascript
// FN Build Availability Request
// Fills the tool envelope from the AUTHENTICATED context (WF-01's database
// lookups), never from model output. Only the args come from the validated AI result.

const p   = $input.first().json;                     // routed item from FN Plan Action
const req = $('TRG Called By Workflow').first().json;
const ctx = $('PG Load AI Context').first().json;

return [{
  json: {
    ...p,
    tool_request: {
      auth: { tool_token: $env.SF_TOOL_TOKEN },
      context: {
        correlation_id: req.correlation_id,
        tenant_slug:    ctx.tenant_slug,
        actor_role:     req.actor_role,
        contact_id:     req.contact_id,
        staff_user_id:  req.staff_user_id || null,
      },
      args: {
        service_code:   p.service_code,
        date:           p.date,
        preferred_time: p.preferred_time,
      },
    },
  },
}];
```

#### `HTTP Tool Check Availability`  (HTTP Request)

| Setting | Value |
|---|---|
| Method | `POST` |
| URL | `http://localhost:5678/webhook/salesfixr/v1/tool/check_availability` |
| Authentication | None (the token is inside the body, per the contract) |
| Send Body | on, **JSON**, **Using JSON** |
| JSON | `{{ JSON.stringify($json.tool_request) }}` |
| Options → Timeout | `15000` |
| Options → Response → **Never Error** | **on** |

**Settings:** On Error → **Continue**.

- **Why `localhost` works from inside Docker:** this call happens *inside* the n8n
  container, and n8n itself listens on port 5678 there. It's n8n calling its own
  front door. (When the tool later moves to another server, this becomes
  `{{ $env.SF_PUBLIC_BASE_URL }}/webhook/…`. One field.)
- **Never Error:** a `401`/`400` from the tool is a *useful answer*, not a crash.
  With this on, the response body reaches the next node whatever the status code.
- **On Error → Continue:** covers "the tool didn't answer at all" (unpublished,
  n8n restarting). The next node turns that into an honest "please call us".

#### `FN Availability Reply`  (Code)

```javascript
// FN Availability Reply
// Turns the tool's answer into what the patient reads. Every time and date in the
// reply comes from the tool's data, never from the model's draft.

const res = $input.first().json;                     // tool response, or { error } if the call failed
// Strip the tool envelope. It contains the tool token, which must never be saved
// to conversations / ai_payload.
const { tool_request, ...plan } = $('FN Build Availability Request').first().json;

const phone = plan.contact_phone_public;
const d = (res && res.data) || {};
const labels = (d.slots || []).map((s) => s.label);
const joinOr = (a) => (a.length <= 1 ? a.join('') : a.slice(0, -1).join(', ') + ' or ' + a[a.length - 1]);
const to12h = (hhmm) => {
  let [h, m] = String(hhmm).split(':').map(Number);
  const ap = h >= 12 ? 'PM' : 'AM';
  h = h % 12 || 12;
  return `${h}:${String(m).padStart(2, '0')} ${ap}`;
};

let reply, status, reason;

if (!res || res.ok === undefined) {
  // No tool answer at all: unpublished tool, timeout, n8n restarting.
  status = 'tool_error'; reason = 'calendar_unavailable';
  reply = `I can't check our calendar right now. Please call us on ${phone} and we'll find you a time.`;
} else if (!res.ok) {
  status = 'tool_refused'; reason = res.reason_code;
  const why = {
    clinic_closed:   `We're closed on ${d.day_label}. Which other day would suit you?`,
    past_date:       'That date has already passed. Which upcoming day would suit you?',
    too_far_ahead:   "That's further ahead than we can book. Could you pick an earlier date?",
    service_unknown: "I couldn't match that service. Which treatment would you like?",
  };
  reply = why[res.reason_code]
    || `I can't check our calendar right now. Please call us on ${phone} and we'll find you a time.`;
} else if (d.requested_available) {
  status = 'slot_available'; reason = 'ok';
  reply = `Good news: ${labels[0]} on ${d.day_label} is free for a ${d.service_name}. Would you like me to book it?`;
} else if (labels.length) {
  status = 'alternatives_offered'; reason = res.reason_code;
  const what = res.reason_code === 'lead_time_too_short' ? 'is a little too soon'
             : res.reason_code === 'slot_outside_hours' ? 'is outside our opening hours'
             : "isn't available";
  reply = `${to12h(d.requested_time)} on ${d.day_label} ${what}. ` +
          `The nearest free times are ${joinOr(labels)}. Would any of those work?`;
} else {
  status = 'no_slots'; reason = 'no_slots';
  reply = `We're fully booked on ${d.day_label}. Would another day work for you?`;
}

return [{
  json: {
    ...plan,
    action_status: status,
    reason_code:   reason,
    reply_text:    reply,
    reply_source:  'template',
    offered_slots: d.slots || [],      // Milestone F books one of exactly these
  },
}];
```

**About "Would you like me to book it?":** this is a question, not a promise. It
claims nothing that hasn't happened. In E, if the patient answers "yes", the router
asks a clarifying question (the "yes" alone has no service or time). Milestone F
teaches it to book one of the `offered_slots` it just showed.

**Save → Publish WF-02.**

---

## E6. End-to-end acceptance tests

Through the whole chain: WF-01 → WF-02 → router → tool → reply. Use a fresh test
patient so the rate limit from B doesn't interfere, and say the **weekday name** of
your test day (from E4.1).

```powershell
$url = "http://localhost:5678/webhook/salesfixr/v1/inbound/test"   # WF-01 Published (D3)
$p = "+1212555" + (Get-Random -Minimum 1000 -Maximum 9999)
function Send-SF($phone, $msg) {
  $body = @{ channel = "test"; phone = $phone; message = $msg } | ConvertTo-Json
  $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -Body $body
  "{0,-22} {1,-22} {2}" -f $r.ai.route, $r.ai.action_status, $r.reply_text
}
```

Replace `Monday` with your test day's weekday:

| # | Send | Expect |
|---|---|---|
| 1 | `Send-SF $p "Can I book a cleaning on Monday at 2pm?"` | `alternatives_offered`: *"2:00 PM on Monday 12 October isn't available. The nearest free times are 1:00 PM, 1:30 PM or 2:30 PM…"* ← **acceptance** |
| 2 | `Send-SF $p "What about a cleaning on Monday at 10am?"` | `slot_available`: *"Good news: 10:00 AM on Monday … is free … Would you like me to book it?"* |
| 3 | `Send-SF $p "Can I book a cleaning on Monday at 4pm?"` | `alternatives_offered`. Google Calendar's "Dentist out" respected |
| 4 | `Send-SF $p "Can I come in on Monday at 2?"` | Still D's question: *"Which service would you like?"* (no service, so no tool call) |

Then check one message's full trail. Take a `correlation_id` from the newest
WF-01 execution, or:

```sql
SELECT workflow, action, status, reason_code,
       coalesce(details->>'route', details->>'offered') AS info
FROM audit_logs
WHERE correlation_id = (SELECT correlation_id FROM audit_logs
                        WHERE workflow = 'TOOL' ORDER BY id DESC LIMIT 1)
ORDER BY id;
```

Three rows, one message: **TOOL** `check_availability` (what was offered) → **WF-02**
`ai_intent` (route `check_availability`) → **WF-01** `safety_gate`. That's the
"explain any decision in ten seconds" screen from the master plan, now with a real
calendar check in the middle.

### Clean up the test data

```sql
DELETE FROM appointments WHERE notes = 'E-TEST';
```

Delete the "Dentist out" event from the calendar.

---

## E7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Tool returns `HTTP 404` | `SF TOOL check_availability` isn't **Published**, or the path has a typo. The production URL only exists while published |
| `HTTP 401` with the right token | `SF_TOOL_TOKEN` not in the container. Check `.env`, then `docker compose up -d`. Or the token has a trailing space in `.env` |
| `calendar_unavailable` on every call | The Google credential isn't connected, has expired (the 7-day Testing limit, see E1.2), or `SF_GOOGLE_CALENDAR_ID` is still the placeholder. Open the GC node and run it alone to see Google's error |
| 4:00 PM shows as free in T3 | The event is on a different calendar, at the wrong time (calendar timezone not New York, see E1.1), or marked *Free* instead of *Busy* (`transparency: transparent` is ignored on purpose) |
| A weekly event isn't blocking anything | Recurring events not expanded. Set the GC node's recurring handling to all occurrences |
| `unknown_tenant` | `tenant_slug` wrong, or E5.1 not done (WF-02 sends `undefined`) |
| Every slot shows `too_soon` | Your test day is today. Use E4.1's date, which is always tomorrow or later |
| Times are 4–5 hours off | Something compared local times to UTC instants. Use the tool's `start`/`end` (UTC, with `Z`) for maths and `local` only for display |
| The chat reply is the old "I can't check live availability just yet" | WF-02 not re-published after E5, or the Switch output still goes to the deleted stub |
| `tool_error` in chat but T1 works by hand | WF-02's HTTP node URL differs from the published path, or *Never Error* is off and On Error isn't Continue |
| The audit row contains the tool token | `FN Availability Reply` must strip `tool_request` (the first lines of its code) |

---

## Done when

- [ ] Google Calendar credential **Connected**. Calendar in New York time.
      `SF_GOOGLE_CALENDAR_ID` set and container recreated
- [ ] `SF TOOL check_availability` built and **Published**
- [ ] Tool tests T1–T8 give the expected results. **T2 returns 3 real alternatives**
- [ ] Every tool call writes a `TOOL` audit row
- [ ] WF-02: slug added to `PG Load AI Context`, stub replaced by the 3 nodes,
      **Published**
- [ ] E6 test 1 offers three real alternatives in chat; test 3 respects the calendar
- [ ] No tool token anywhere in `conversations.ai_payload` or `audit_logs.details`:
      ```sql
      SELECT count(*) FROM conversations WHERE ai_payload::text ILIKE '%tool_token%';
      SELECT count(*) FROM audit_logs   WHERE details::text    ILIKE '%tool_token%';
      ```
      Both must be `0`.
- [ ] Test data cleaned up. All workflows exported (including the new tool) and committed:

```powershell
cd F:\Agency\Automation_MVP
git add docs workflows tests
git commit -m "Milestone E: check_availability tool (Postgres + Google Calendar), wired into router"
git push
```

**Next:** Milestone F — booking end-to-end: hold the slot, create the calendar
event, confirm from the database row, alert the owner on Telegram.
`docs/10-MILESTONE-F.md`.
