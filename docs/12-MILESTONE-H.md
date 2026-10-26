# Milestone H — Reminders

**Goal:** every booking automatically gets its reminders: **24 hours** and **2 hours**
before the appointment (the defaults in `clinic_settings.reminder_offsets_hours`).
They go out on the channel the patient booked on, never during quiet hours, never
to someone who opted out, and never for an appointment that was cancelled.

**Why now:** F already writes a `reminders` row for each offset when it books. G
gave us a way to *send* (WF-09). H connects the two with a workflow that wakes up
every 15 minutes and drains the due rows.

**Time:** about 2 hours. One small migration, one new workflow of 9 nodes, no
changes to WF-01/WF-02.

**Prerequisite:** Milestone G green: WF-09 published, Messenger/Instagram replies working.
(The test-channel parts of H work even without G, but WF-09 must exist.)

**Acceptance test (master plan):** book for tomorrow → reminder rows are created,
and they fire.

---

## H0. What gets built

```
SF WF-04 Reminders                                    (new; runs every 15 minutes)
  SCH Every 15 Minutes
   → PG Housekeeping              releases expired holds, expires old offers, unsticks rows
   → PG Claim Due Reminders       due + not in quiet hours → status 'sending'  (one statement)
   → FN Decide Reminder           send or skip, and the text. Deterministic, no AI
   → IF Should Send
        true  → SUB Call WF-09 Send  → PG Mark Send Result     sent / failed + conversation row
        false → PG Mark Skipped      → IF Notify Owner → TG Notify Owner Reminder
```

### The rules, in the order they're checked

| # | Check | Outcome | Reason code |
|---|---|---|---|
| 1 | `send_at` not reached yet | not claimed, stays `pending` | — |
| 2 | Clinic is in **quiet hours** (21:00–08:00 local by default) | not claimed, stays `pending`; the first run after 08:00 sends it | — |
| 3 | Appointment no longer `booked` (cancelled, no-show…) | `skipped` | `appointment_not_booked` |
| 4 | Appointment starts in less than 30 minutes (n8n was off for hours) | `skipped` | `too_late` |
| 5 | Patient opted out, or withdrew appointment consent | `skipped` | `opted_out` |
| 6 | Channel we can't send on yet (`voice`, `sms`…) | `skipped` | `channel_unsupported` |
| 7 | No address for that channel (no PSID on file) | `skipped` | `no_address` |
| 8 | **Messenger or Instagram, and the patient hasn't messaged us on that channel in the last 24 h** | `skipped` + **Telegram to the owner**: "please call them" | `outside_messaging_window` |
| — | Otherwise | sent through WF-09 → `sent`, or `failed` with WF-09's reason | `ok` / `send_failed` |

**Rule 2, quiet hours.** Milestone B deliberately did **not** apply quiet hours to
replies ("never ignore a patient who just wrote to us"). This is the first message
*we* start, so this is where quiet hours finally apply. A 2-hour reminder for an
8:30 AM appointment falls at 6:30, inside quiet hours: it waits until 08:00 and
goes out then, still 30 minutes before the appointment.

**Rule 8, Meta's 24-hour window.** Messenger and Instagram only let a business
message someone within 24 hours of *their* last message on that channel. Until early 2026 the
`CONFIRMED_EVENT_UPDATE` message tag allowed appointment reminders outside that
window. **Meta retired that tag in 2026**, and its replacement (*utility message
templates*, pre-approved by Meta) is only available in a few countries and needs
App Review. So the MVP does the honest thing:

- A 2-hour reminder for a booking made the day before usually **is** inside the
  window (the patient messaged yesterday to book) **only if** they booked less than
  ~22 hours before the appointment. Often it isn't.
- When it isn't, the bot does **not** try and fail silently: the reminder is marked
  `skipped / outside_messaging_window` and **the owner gets a Telegram** with the
  patient's name, phone and appointment so a person can call.

That's the right product behaviour too. A missed reminder costs the clinic a
no-show, so a human fallback beats a silent one. Utility templates are a
post-MVP upgrade inside WF-09 only (master plan §8).

**Why claim-then-send (the `sending` status):** if two runs overlap (a slow run, or
you clicking *Execute workflow* while the schedule fires), both could read the same
due row and send it twice. `PG Claim Due Reminders` selects due rows **and** marks
them `sending` in a single statement with `FOR UPDATE SKIP LOCKED`, so each row
belongs to exactly one run. A row that stays `sending` for 30 minutes (n8n crashed
mid-run) is marked `failed / stuck_sending`, never re-sent blindly: a missed
reminder is better than a duplicate one.

### A fix for Milestone F, included here

F's `book_appointment` places a 5-minute **hold** before creating the calendar
event. If the calendar step fails, the hold stays `held`. The doc said it "expires
by itself", but nothing actually flipped it, and the no-double-booking constraint
counts `held` rows. So a failed booking blocked its slot **forever**. WF-04's
`PG Housekeeping` now releases expired holds every 15 minutes (`cancelled /
hold_expired`). Same for booking offers past their 30 minutes.

---

## H1. Migration 007

Neon → SQL Editor → paste and **Run** the whole file
`db/007_reminder_claim.sql`:

```sql
-- =====================================================================
-- 007 — Reminder sending support (Milestone H)
--
-- 'sending' marks a reminder WF-04 has claimed but not finished. A
-- reminder is claimed and marked in ONE statement, so two runs that
-- overlap can never send the same reminder twice.
--
-- Safe to re-run. Run it as its own script (Postgres won't let a new
-- enum value be used in the same transaction that adds it; this script
-- only adds it).
-- =====================================================================

ALTER TYPE reminder_status_t ADD VALUE IF NOT EXISTS 'sending';

ALTER TABLE reminders
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz;

COMMENT ON COLUMN reminders.claimed_at IS
  'When WF-04 claimed the row (status became sending). A row stuck in sending '
  'for 30+ minutes is marked failed by WF-04 housekeeping, never re-sent.';
```

**Check:**

```sql
SELECT enum_range(NULL::reminder_status_t);
```

Expect `{pending,sent,skipped,failed,sending}`.

---

## H2. New things in this milestone — read once

### Schedule Trigger — we name it `SCH …`

*Node picker → **Schedule Trigger**.* Starts the workflow on a timer. It only runs
while the workflow is **Published** and n8n is running. Your PC asleep = no runs.
That's fine: the next run picks up everything that became due in the meantime
(rule 4 stops reminders for appointments that already started).

Add `SCH` to your mental list of prefixes (`docs/02-NAMING-CONVENTIONS.md` has it now).

### Execute Workflow, "Run once for each item"

Until now every `SUB …` node received **one** item. Here `FN Decide Reminder` can
output up to 25 reminders at once. WF-09 reads its input with `.first()`, so it must
be called **once per reminder**:

**SUB node → Mode: _Run once for each item_.**

With the default (*Run once with all items*) WF-09 would receive all 25 at once,
send the first, and silently drop 24.

### Why every result node reads `$json`, never another node by name

After a sub-workflow call, "which input item does this output belong to" can get
lost. So nothing downstream relies on it: WF-09 echoes back the `correlation_id`
(we pass the **reminder id** as the correlation id) and the `text`, and the
`PG Mark…` nodes use only `$json`. Each item carries everything it needs.

---

## H3. Build WF-04 — Reminders

New workflow: **`SF WF-04 Reminders`**. Tags: `salesfixr`, `scheduled`.
**Settings (top-right ⋯ → Settings) → Timezone: `America/New_York`** (the clinic's
zone; it only affects how the schedule is displayed).

> **How to add each node below.** Click the **+** on the right edge of the previous
> node (or press **Tab** on the canvas, or the **+** at top right). A search box opens:
> type what each node's **Add it** line says and click that result. Then **rename** the
> node to the name in the heading: double-click its title at the top of the panel (or
> select it on the canvas and press **F2**) and type the name exactly. The 2-to-5-letter
> prefix (`FN`, `PG`, `TRG`…) is only part of our naming convention
> (`docs/02-NAMING-CONVENTIONS.md`); it is **not** something you search for.


### Node 1 — `SCH Every 15 Minutes`  (Schedule Trigger)

**Add it:** search **`Schedule Trigger`** → click it. This is the workflow's first node: on an empty canvas click **Add first step** and search there.

| Setting | Mode | Value |
|---|---|---|
| Trigger Interval | Fixed | **Minutes** |
| Minutes Between Triggers | Fixed | `15` |

### Node 2 — `PG Housekeeping`  (Postgres → Execute Query)

**Add it:** search **`Postgres`** → in the action list click **Execute a SQL query** → Credential: **`Postgres account`**.

Credential: `Postgres account`. **Settings → Always Output Data: ON.**
No Query Parameters.

```sql
WITH expired_holds AS (
  -- A hold whose calendar step failed would otherwise block the slot forever.
  UPDATE appointments
     SET status = 'cancelled', cancel_reason = 'hold_expired', hold_expires_at = NULL
   WHERE status = 'held' AND hold_expires_at < now()
  RETURNING id
),
expired_offers AS (
  UPDATE booking_offers SET status = 'expired'
   WHERE status = 'open' AND expires_at < now()
  RETURNING id
),
stuck AS (
  -- Claimed but never finished (n8n stopped mid-run). Mark failed; never re-send blindly.
  UPDATE reminders
     SET status = 'failed', skip_reason = 'stuck_sending'
   WHERE status = 'sending' AND claimed_at < now() - interval '30 minutes'
  RETURNING id
)
SELECT (SELECT count(*) FROM expired_holds)  AS holds_released,
       (SELECT count(*) FROM expired_offers) AS offers_expired,
       (SELECT count(*) FROM stuck)          AS reminders_unstuck;
```

It always returns exactly one row (three counts), so the workflow continues.

**Connect:** `SCH Every 15 Minutes` → this node.

### Node 3 — `PG Claim Due Reminders`  (Postgres → Execute Query)

**Add it:** search **`Postgres`** → in the action list click **Execute a SQL query** → Credential: **`Postgres account`**.

Credential: `Postgres account`. **Always Output Data: OFF** (leave the default).
No Query Parameters.

```sql
WITH due AS (
  SELECT r.id
  FROM reminders r
  JOIN tenants t         ON t.id = r.tenant_id AND t.is_active
  JOIN clinic_settings s ON s.tenant_id = r.tenant_id
  WHERE r.status = 'pending'
    AND r.send_at <= now()
    -- Quiet hours apply to messages WE start (doc 06 §B). Inside them the row
    -- simply stays pending and is picked up by the first run after they end.
    AND NOT (CASE WHEN s.quiet_hours_start > s.quiet_hours_end
                  THEN ((now() AT TIME ZONE t.timezone)::time >= s.quiet_hours_start
                        OR (now() AT TIME ZONE t.timezone)::time <  s.quiet_hours_end)
                  ELSE ((now() AT TIME ZONE t.timezone)::time >= s.quiet_hours_start
                        AND (now() AT TIME ZONE t.timezone)::time <  s.quiet_hours_end)
             END)
  ORDER BY r.send_at
  LIMIT 25
  FOR UPDATE OF r SKIP LOCKED
),
claimed AS (
  UPDATE reminders r
     SET status = 'sending', claimed_at = now()
    FROM due
   WHERE r.id = due.id
  RETURNING r.*
)
SELECT c.id::text                                                  AS reminder_id,
       c.offset_hours,
       c.channel::text                                             AS channel,
       t.slug                                                      AS tenant_slug,
       s.clinic_name,
       s.phone_public,
       s.telegram_chat_id,
       a.status::text                                              AS appointment_status,
       (a.start_time - now()) > interval '30 minutes'              AS still_ahead,
       to_char(a.start_time AT TIME ZONE t.timezone, 'FMDay DD FMMonth') AS day_label,
       to_char(a.start_time AT TIME ZONE t.timezone, 'FMHH12:MI AM')     AS time_label,
       COALESCE(sv.display_name, a.service_code)                   AS service_name,
       ct.full_name                                                AS patient_name,
       ct.phone_e164                                               AS patient_phone,
       (ct.opted_out OR NOT ct.appointment_consent)                AS opted_out,
       ci.external_contact_id                                      AS address,
       (SELECT max(cv.created_at) > now() - interval '23 hours 30 minutes'
          FROM conversations cv
         WHERE cv.contact_id = c.contact_id AND cv.channel = c.channel
           AND cv.direction = 'inbound')                           AS in_messaging_window
FROM claimed c
JOIN appointments a    ON a.id = c.appointment_id
JOIN tenants t         ON t.id = c.tenant_id
JOIN clinic_settings s ON s.tenant_id = c.tenant_id
JOIN contacts ct       ON ct.id = c.contact_id
LEFT JOIN services sv  ON sv.tenant_id = a.tenant_id AND sv.code = a.service_code
LEFT JOIN LATERAL (
  SELECT external_contact_id FROM contact_identities
   WHERE contact_id = c.contact_id AND channel = c.channel
   ORDER BY created_at DESC LIMIT 1
) ci ON true;
```

Zero due reminders → zero rows → the workflow simply ends here. That's the normal
case for most runs.

- `LIMIT 25`: a backlog (n8n was off for a day) is drained 25 per run, not all at
  once.
- `in_messaging_window`: was the patient's last message **on this channel**
  within 23 h 30 min? (30 minutes of margin so a slow run doesn't cross the line.)

**Connect:** `PG Housekeeping` → this node.

### Node 4 — `FN Decide Reminder`  (Code, **Run Once for All Items**)

**Add it:** search **`Code`** → click **Code** (Language: **JavaScript**). Delete the sample code before pasting.

```javascript
// FN Decide Reminder
// One item per claimed reminder. Decides SEND or SKIP, and writes the text.
// Deterministic: no AI writes reminders. Every skip has a reason code.

return $input.all().map((it) => {
  const r = it.json;
  const name = r.patient_name ? ` ${r.patient_name}` : '';
  const when = Number(r.offset_hours) <= 3
    ? `today at ${r.time_label}`
    : `on ${r.day_label} at ${r.time_label}`;
  const text =
    `Hi${name}, this is a reminder from ${r.clinic_name}: your ${r.service_name} is ${when}. ` +
    `If you need to change it, reply here or call us on ${r.phone_public}.`;

  let skip = null;
  if (r.appointment_status !== 'booked')            skip = 'appointment_not_booked';
  else if (r.still_ahead !== true)                  skip = 'too_late';
  else if (r.opted_out === true)                    skip = 'opted_out';
  else if (!['test', 'messenger', 'instagram'].includes(r.channel)) skip = 'channel_unsupported';
  else if (!r.address)                              skip = 'no_address';
  else if (['messenger', 'instagram'].includes(r.channel) && r.in_messaging_window !== true)
                                                    skip = 'outside_messaging_window';

  // Meta (Messenger + Instagram) only lets us message someone within 24 h of THEIR
  // last message on that channel. Outside that,
  // a human has to make the call, so the owner gets told who to phone.
  const notify_owner = skip === 'outside_messaging_window' && !!r.telegram_chat_id;
  const telegram_text = notify_owner
    ? `⏰ Reminder not sent: ${r.patient_name || 'a patient'} (${r.patient_phone || 'no phone on file'}) ` +
      `hasn't messaged us on ${r.channel} in the last 24 h, so Meta won't deliver it.\n` +
      `${r.service_name}, ${r.day_label} at ${r.time_label}. Please call them.`
    : '';

  return { json: {
    reminder_id: r.reminder_id,
    tenant_slug: r.tenant_slug,
    channel: r.channel,
    address: r.address || '',
    text,
    messaging_type: 'UPDATE',
    decision: skip ? 'skip' : 'send',
    skip_reason: skip || '',
    notify_owner,
    telegram_chat_id: r.telegram_chat_id || '',
    telegram_text,
  } };
});
```

**Connect:** `PG Claim Due Reminders` → this node.

### Node 5 — `IF Should Send`  (If)

**Add it:** search **`If`** → click **If**.

One condition:

| Field | Mode | Value |
|---|---|---|
| value 1 (left) | **Expression** | `{{ $json.decision }}` |
| operator | — | **String → is equal to** |
| value 2 (right) | Fixed | `send` |

**true** → node 6. **false** → node 8.

### Node 6 — `SUB Call WF-09 Send`  (Execute Workflow)

**Add it:** search **`Execute Workflow`** → in the action list click **Execute A Sub Workflow** (shown as *Execute Workflow* on the canvas).

| Setting | Mode | Value |
|---|---|---|
| Source | — | Database |
| Workflow | — | **From list** → `SF WF-09 Outbound Router` |
| **Mode** | — | **Run once for each item** |
| Options → Wait For Sub-Workflow Completion | — | on |

Workflow Inputs (all **Expression** except where marked):

| Field | Value |
|---|---|
| `correlation_id` | `{{ $json.reminder_id }}` |
| `tenant_slug` | `{{ $json.tenant_slug }}` |
| `channel` | `{{ $json.channel }}` |
| `address` | `{{ $json.address }}` |
| `text` | `{{ $json.text }}` |
| `messaging_type` | `{{ $json.messaging_type }}` |

**Settings:** On Error → **Continue**. No Retry On Fail (a retry could double-send).

> If you built WF-09 before this doc was updated: open WF-09 → `FN Send Result` and
> make sure its `return` includes `text: req.text` (G5 node 6). Node 7 below
> needs it.

**Connect:** `IF Should Send` **true** → this node.

### Node 7 — `PG Mark Send Result`  (Postgres → Execute Query)

**Add it:** search **`Postgres`** → in the action list click **Execute a SQL query** → Credential: **`Postgres account`**.

Credential: `Postgres account`. **Always Output Data: ON.**

```sql
WITH upd AS (
  UPDATE reminders
     SET status      = CASE WHEN $2::boolean THEN 'sent' ELSE 'failed' END::reminder_status_t,
         sent_at     = CASE WHEN $2::boolean THEN now() END,
         skip_reason = CASE WHEN $2::boolean THEN NULL ELSE $3 END
   WHERE id = NULLIF($1, '')::uuid AND status = 'sending'
  RETURNING id, tenant_id, contact_id, channel, status
),
conv AS (
  -- What we said, next to the patient's own messages (the dashboard inbox reads this).
  INSERT INTO conversations (tenant_id, contact_id, actor_role, channel, direction, body, message_type)
  SELECT tenant_id, contact_id, 'system', channel, 'outbound', $4, 'reminder'
  FROM upd WHERE $2::boolean
  RETURNING id
),
aud AS (
  INSERT INTO audit_logs (tenant_id, contact_id, workflow, action, status, reason_code, correlation_id, details)
  SELECT tenant_id, contact_id, 'WF-04', 'send_reminder',
         CASE WHEN $2::boolean THEN 'ok' ELSE 'error' END,
         CASE WHEN $2::boolean THEN 'ok' ELSE $3 END,
         id::text, jsonb_build_object('channel', channel, 'error', NULLIF($5, ''))
  FROM upd
  RETURNING id
)
SELECT (SELECT id::text FROM upd)     AS reminder_id,
       (SELECT status::text FROM upd) AS status,
       (SELECT count(*) FROM conv)    AS conversation_rows;
```

**Query Parameters** (Expression):

```
{{ [ $json.correlation_id || '', $json.ok === true, $json.reason_code || 'send_failed', $json.text || '', $json.error || '' ] }}
```

- `$1` = the reminder id WF-09 echoed back as `correlation_id`.
- If the WF-09 call itself crashed, the item has no `correlation_id`: `$1` is empty,
  nothing is updated, and housekeeping marks the row `failed / stuck_sending` 30
  minutes later. Nothing is ever sent twice.

**Connect:** `SUB Call WF-09 Send` → this node. Last node of this branch.

### Node 8 — `PG Mark Skipped`  (Postgres → Execute Query)

**Add it:** search **`Postgres`** → in the action list click **Execute a SQL query** → Credential: **`Postgres account`**.

Credential: `Postgres account`. **Always Output Data: ON.**

```sql
WITH upd AS (
  UPDATE reminders
     SET status = 'skipped', skip_reason = $2
   WHERE id = $1::uuid AND status = 'sending'
  RETURNING id, tenant_id, contact_id, channel
),
aud AS (
  INSERT INTO audit_logs (tenant_id, contact_id, workflow, action, status, reason_code, correlation_id, details)
  SELECT tenant_id, contact_id, 'WF-04', 'send_reminder', 'blocked', $2, id::text,
         jsonb_build_object('channel', channel)
  FROM upd
  RETURNING id
)
SELECT (SELECT id::text FROM upd)  AS reminder_id,
       $2                          AS skip_reason,
       ($3::boolean AND EXISTS (SELECT 1 FROM upd)) AS notify_owner,
       $4                          AS telegram_chat_id,
       $5                          AS telegram_text;
```

**Query Parameters** (Expression):

```
{{ [ $json.reminder_id, $json.skip_reason, $json.notify_owner, $json.telegram_chat_id, $json.telegram_text ] }}
```

**Connect:** `IF Should Send` **false** → this node.

### Node 9 — `IF Notify Owner`  (If)

**Add it:** search **`If`** → click **If**.

| Field | Mode | Value |
|---|---|---|
| value 1 | **Expression** | `{{ $json.notify_owner }}` |
| operator | — | **Boolean → is true** |

**true** → node 10. **false** → nothing (leave it empty).

**Connect:** `PG Mark Skipped` → this node.

### Node 10 — `TG Notify Owner Reminder`  (Telegram → Send a text message)

**Add it:** search **`Telegram`** → in the action list click **Send a text message** → Credential: **`SalesFixr Telegram`**.

| Setting | Mode | Value |
|---|---|---|
| Credential | — | `SalesFixr Telegram` |
| Chat ID | **Expression** | `{{ $json.telegram_chat_id }}` |
| Text | **Expression** | `{{ $json.telegram_text }}` |
| Additional Fields → Append n8n Attribution | — | off |

**Settings:** On Error → **Continue**.

### Wiring table — `SF WF-04 Reminders`

Draw exactly these connections, and nothing else. "→" means: drag from the **output** dot on the right of the first node to the **input** dot on the left of the second.

| # | From (output) | To (input) |
|---|---|---|
| 1 | `SCH Every 15 Minutes` | `PG Housekeeping` |
| 2 | `PG Housekeeping` | `PG Claim Due Reminders` |
| 3 | `PG Claim Due Reminders` | `FN Decide Reminder` |
| 4 | `FN Decide Reminder` | `IF Should Send` |
| 5 | `IF Should Send` **true** | `SUB Call WF-09 Send` |
| 6 | `IF Should Send` **false** | `PG Mark Skipped` |
| 7 | `SUB Call WF-09 Send` | `PG Mark Send Result` (end) |
| 8 | `PG Mark Skipped` | `IF Notify Owner` |
| 9 | `IF Notify Owner` **true** | `TG Notify Owner Reminder` (end) |
| 10 | `IF Notify Owner` **false** | nothing, leave it empty |

**Check:** 10 nodes, 9 lines. `SUB Call WF-09 Send` shows **Run once for each item**.
In both IF nodes the left box has a green preview (Expression mode).

**Save → Publish.** From now on it runs every 15 minutes by itself.

---

## H4. Tests

All on the **test channel** first (WF-09's `test` branch counts as delivered), then
one real Messenger reminder.

Load the helpers in PowerShell:

```powershell
cd F:\Agency\Automation_MVP
. .\tests\sf-helpers.ps1
```

### H4.1 Make a booking for tomorrow

Pick tomorrow if it's a weekday the clinic is open, else the next open day.
Use a time at least 3 hours from now (clinic time):

```powershell
$p = New-TestPhone
Send-SF $p "Hi, can I book a cleaning tomorrow at 2pm?"
Start-Sleep 5
Send-SF $p "Yes please, my name is Rem Test"
```

Expect `booked`. Then in Neon:

```sql
SELECT r.offset_hours, r.status, r.channel,
       r.send_at AT TIME ZONE 'America/New_York' AS send_at_local
FROM reminders r JOIN contacts c ON c.id = r.contact_id
WHERE c.phone_e164 = 'PASTE-$p-HERE'
ORDER BY r.offset_hours DESC;
```

Expect two rows (24 and 2), `pending`, `test`. If the appointment is less than 24 h
away, only the 2-hour row exists. That's correct: F never creates a reminder whose
time has already passed.

### H4.2 Time travel: make them due now

Instead of waiting a day, move `send_at` into the past for **this patient only**:

```sql
UPDATE reminders SET send_at = now() - interval '1 minute'
WHERE contact_id = (SELECT id FROM contacts WHERE phone_e164 = 'PASTE-$p-HERE')
  AND status = 'pending';
```

Open WF-04 → **Execute workflow** (bottom). Quiet hours: if it's currently between
21:00 and 08:00 **New York time**, nothing is claimed (correct!). For testing,
temporarily switch them off and remember to restore them afterwards:

```sql
UPDATE clinic_settings SET quiet_hours_start = '00:00', quiet_hours_end = '00:00'
WHERE tenant_id = (SELECT id FROM tenants WHERE slug = 'demo_clinic');
```

(`00:00`–`00:00` = an empty window.)

### H4.3 The test table

Each row: run the setup, click **Execute workflow** in WF-04, then run the check
query under the table. `$p` stands for the phone of the booking you made in H4.1
(paste it into the SQL); for H-T3 to H-T5 make a **new** booking with a new
`$p = New-TestPhone` first, exactly as in H4.1.

| # | Setup | Expect after one run |
|---|---|---|
| H-T1 | H4.2 time travel for the H4.1 patient | both rows `sent`; `conversations` has two `outbound` rows with `message_type = 'reminder'`; audit `WF-04 send_reminder ok` ×2 |
| H-T2 | Click **Execute workflow** again right away | nothing claimed: the run ends at `PG Claim Due Reminders` with 0 items |
| H-T3 | New booking. Cancel it (SQL A below), then time travel | `skipped / appointment_not_booked` |
| H-T4 | New booking. Opt the patient out (SQL B), then time travel | `skipped / opted_out` |
| H-T5 | New booking. Put *now* inside quiet hours (SQL C), time travel, run | rows **stay `pending`**, nothing claimed. Then SQL D (empty window) and run again → `sent` |
| H-T6 | An expired hold (SQL E) | `PG Housekeeping` shows `holds_released: 1`; that row is `cancelled / hold_expired` |

```sql
-- A: cancel this patient's booking
UPDATE appointments SET status = 'cancelled', cancel_reason = 'H-T3'
WHERE contact_id = (SELECT id FROM contacts WHERE phone_e164 = 'PASTE-PHONE');

-- B: opt this patient out
UPDATE contacts SET opted_out = true, opted_out_at = now() WHERE phone_e164 = 'PASTE-PHONE';

-- C: quiet hours = the next 2 hours, clinic time
UPDATE clinic_settings
   SET quiet_hours_start = date_trunc('hour', now() AT TIME ZONE 'America/New_York')::time,
       quiet_hours_end   = (date_trunc('hour', now() AT TIME ZONE 'America/New_York') + interval '2 hours')::time
WHERE tenant_id = (SELECT id FROM tenants WHERE slug = 'demo_clinic');

-- D: empty quiet window again (testing only; H4.5 restores the real one)
UPDATE clinic_settings SET quiet_hours_start = '00:00', quiet_hours_end = '00:00'
WHERE tenant_id = (SELECT id FROM tenants WHERE slug = 'demo_clinic');

-- E: a hold that expired a minute ago, three days out
INSERT INTO appointments (tenant_id, contact_id, service_code, start_time, end_time, status, hold_expires_at, source_channel, notes)
SELECT t.id, c.id, 'dental_cleaning', now() + interval '3 days', now() + interval '3 days 30 minutes',
       'held', now() - interval '1 minute', 'test', 'H-T6'
FROM tenants t JOIN contacts c ON c.tenant_id = t.id AND c.phone_e164 = 'PASTE-PHONE'
WHERE t.slug = 'demo_clinic';
```

Check query (all rows touched in the last hour, plus anything still pending):

```sql
SELECT c.phone_e164, r.offset_hours, r.status, r.skip_reason, r.sent_at
FROM reminders r JOIN contacts c ON c.id = r.contact_id
WHERE r.claimed_at > now() - interval '1 hour' OR r.status = 'pending'
ORDER BY r.created_at DESC LIMIT 20;
```

### H4.4 Real Messenger reminders (from your phone)

*Instagram works exactly the same way: book by Instagram DM and use `channel =
'instagram'` and your IGSID in the SQL below.*

You need to book **as a patient** on Messenger. If you promoted yourself to owner in
G9.2 and have no tester account, switch your owner row off for this test:

```sql
UPDATE staff_users SET is_active = false WHERE channel = 'messenger' AND external_contact_id = 'PASTE-PSID';
```

1. From the phone, book a cleaning for tomorrow at least 3 hours ahead
   ("…tomorrow at 2pm?" → "Yes please, my name is …"). Expect two pending
   `messenger` reminders (or one, if the appointment is under 24 h away).

2. **H-T7, outside the 24 h window.** Pretend your last message was 2 days ago
   (test data only), then make only the **24 h** reminder due:

```sql
UPDATE conversations SET created_at = created_at - interval '2 days'
WHERE channel = 'messenger' AND direction = 'inbound'
  AND contact_id = (SELECT contact_id FROM contact_identities
                    WHERE channel = 'messenger' AND external_contact_id = 'PASTE-PSID');

UPDATE reminders SET send_at = now() - interval '1 minute'
WHERE status = 'pending' AND channel = 'messenger' AND offset_hours = 24
  AND contact_id = (SELECT contact_id FROM contact_identities
                    WHERE channel = 'messenger' AND external_contact_id = 'PASTE-PSID');
```

   **Execute workflow** → no Messenger message; reminder `skipped /
   outside_messaging_window`; **Telegram: "⏰ Reminder not sent: … Please call
   them."**

3. **H-T8, inside the window.** Send the Page any message from the phone (e.g.
   "thanks"); that reopens the window. Make the **2 h** reminder due:

```sql
UPDATE reminders SET send_at = now() - interval '1 minute'
WHERE status = 'pending' AND channel = 'messenger' AND offset_hours = 2
  AND contact_id = (SELECT contact_id FROM contact_identities
                    WHERE channel = 'messenger' AND external_contact_id = 'PASTE-PSID');
```

   **Execute workflow** → the phone receives *"Hi …, this is a reminder from
   SmileCare Dental: your Dental Cleaning is today at …"*. WF-09's audit row:
   `send ok`.

4. Switch your owner row back on if you switched it off:

```sql
UPDATE staff_users SET is_active = true WHERE channel = 'messenger' AND external_contact_id = 'PASTE-PSID';
```

### H4.5 Restore and clean up

```sql
-- real quiet hours back
UPDATE clinic_settings SET quiet_hours_start = '21:00', quiet_hours_end = '08:00'
WHERE tenant_id = (SELECT id FROM tenants WHERE slug = 'demo_clinic');

-- the H-T4 patient opted back in
UPDATE contacts SET opted_out = false, opted_out_at = NULL WHERE phone_e164 = 'PASTE-H-T4-PHONE';

-- cancel every test booking made in this milestone (test phones + your Messenger test)
UPDATE appointments SET status = 'cancelled', cancel_reason = 'H test'
WHERE status IN ('booked', 'held')
  AND contact_id IN (
    SELECT id FROM contacts WHERE phone_e164 IN ('PHONE-1', 'PHONE-2', 'PHONE-3', 'PHONE-4')
    UNION
    SELECT contact_id FROM contact_identities WHERE channel = 'messenger' AND external_contact_id = 'PASTE-PSID');
```

Then delete those events from the Google Calendar. Pending reminders of cancelled
appointments need no cleanup: WF-04 skips them (`appointment_not_booked`).

---

## H5. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| WF-04 never runs by itself | Not **Published**, or n8n/PC was off. Executions list shows a run every 15 min when it's working |
| Every run ends at `PG Claim Due Reminders` with 0 items, but rows are due | Quiet hours (NY time!), `tenants.is_active` false, or `send_at` still in the future. Run the claim's `WHERE` parts as a SELECT to see which one |
| `invalid input value for enum reminder_status_t: "sending"` | Migration 007 not run |
| Only the first of several due reminders is sent; the rest stay `sending` and later become `stuck_sending` | `SUB Call WF-09 Send` Mode is *Run once with all items*. Set **Run once for each item** |
| Rows stay `sending`; `PG Mark Send Result` updated 0 rows | WF-09's output has no `correlation_id`/`text`. Check G5 `FN Send Result` returns them |
| Messenger reminder `failed`, error `(#10) … outside of allowed window` | The 24 h check passed but Meta disagrees (clock skew, or the last inbound was on another account). It's recorded as failed; nothing else to do |
| Messenger reminder `failed`, `(#100) … messaging_type` | WF-09's JSON still hard-codes `RESPONSE`, or `messaging_type` isn't a WF-09 input. Re-check G5 node 1 and node 3 |
| Telegram for `outside_messaging_window` doesn't arrive | `clinic_settings.telegram_chat_id` empty (then `notify_owner` is false by design), or Telegram credential issue (see F9) |
| Reminder says the wrong time | `tenants.timezone` (America/New_York). The labels are computed in Postgres from it, not from n8n's timezone |

---

## Done when

- [ ] Migration 007 run; `sending` in the enum
- [ ] `SF WF-04 Reminders` built per the wiring table and **Published**; runs every 15 min on its own
- [ ] H-T1 to H-T6 pass on the test channel
- [ ] H-T7: outside the 24 h window → skipped + Telegram to the owner
- [ ] H-T8: a real Messenger reminder arrives on your phone
- [ ] Quiet hours restored to 21:00–08:00; test bookings cancelled; calendar cleaned
- [ ] Exported and committed:

```powershell
cd F:\Agency\Automation_MVP
git add db docs workflows
git commit -m "Milestone H: reminders (claim-then-send, quiet hours, 24h window fallback, hold cleanup)"
git push
```

**Next:** Milestone I — voice. An ElevenLabs agent that books by phone using the
**same** tool endpoints. `docs/13-MILESTONE-I.md`.
