# Milestone B — Safety Gate + Audit Log

**Goal:** before any AI exists, make WF-01 decide *deterministically* whether we are
allowed to reply at all — and record every decision.

**Why this comes before the AI:** if you add the model first, you will be tempted to
let it handle "STOP". That is the single most expensive mistake in this product
category. Opt-out is a legal obligation, not a conversational nicety. Build the wall
first, then put the AI behind it.

**Time:** about 60 minutes.

**Prerequisite:** Milestone A green, WF-01 exported to `workflows/exports/`.

---

## B1. Run the migration

`db/003_add_ai_pause.sql` adds `contacts.ai_paused_until`. Paste it into the Neon
SQL Editor and run it.

Why now: when a patient asks for a human, the AI must *stop talking* on that thread
until staff release it. Without this column, "escalate to a human" is only a
notification and the bot keeps talking over your staff member. The gate reads it
from this milestone on; WF-06 sets it later.

Verify:

```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'contacts' AND column_name = 'ai_paused_until';
```

---

## B2. The design decision you need to understand first

**Quiet hours must NOT block a reply to an inbound message.**

The obvious reading of "quiet hours 21:00–08:00" is *don't contact people at night*.
That is correct for messages **we initiate** — reminders, marketing, follow-ups.
It is wrong for a **reply to someone who just messaged us**. A patient who writes at
11 PM and gets silence thinks the clinic is broken, and you will have "fixed" nothing.

So the gate has two modes:

| Check | Inbound reply | Outbound we initiate |
|---|---|---|
| Opt-out keyword | ✅ | — |
| Contact opted out | ✅ | ✅ |
| AI paused (escalated) | ✅ | ✅ |
| Rate limit | ✅ | ✅ |
| **Quiet hours** | ❌ **never** | ✅ |
| Marketing consent | ❌ | ✅ (marketing only) |

This milestone builds the **inbound** column. Milestone H reuses the same code for
the outbound column, where `in_quiet_hours` finally does block something. We compute
`in_quiet_hours` now anyway and write it to the audit log, so the data is there.

---

## B3. What WF-01 becomes

Five new nodes, inserted between `PG Insert Inbound Message` and `RESP Ack`:

```
WH Inbound Test
  → FN Normalize Inbound
  → PG Resolve Contact And Role
  → PG Insert Inbound Message
  → PG Load Gate Context          ← new
  → FN Safety Gate                ← new  (the deterministic rules)
  → SW Gate Decision              ← new  (3 outputs)
       ├─ opt_out → PG Apply Opt Out   ← new
       ├─ block   ──────────────────┐
       └─ allow   ──────────────────┤
                                    ↓
                      PG Write Audit Log     ← new
                      → RESP Ack             (existing, body changes)
```

All three branches converge on `PG Write Audit Log`. In n8n you do this by dragging
connections from each branch output onto the same node input — that is supported and
is how you avoid duplicating the audit logic three times.

---

### Node 5 — `PG Load Gate Context`  (Postgres, Execute Query)

Everything the gate needs, in one round trip. The gate itself then does no I/O,
which is what makes it easy to reason about and impossible to half-fail.

```sql
SELECT
  t.id                                     AS tenant_id,
  t.timezone                               AS tenant_timezone,
  (now() AT TIME ZONE t.timezone)::time    AS local_time,
  s.max_msgs_per_contact_per_day,
  c.opted_out,
  c.appointment_consent,
  c.marketing_consent,
  (c.ai_paused_until IS NOT NULL AND c.ai_paused_until > now()) AS ai_paused,
  CASE WHEN s.quiet_hours_start > s.quiet_hours_end
       THEN ((now() AT TIME ZONE t.timezone)::time >= s.quiet_hours_start
             OR (now() AT TIME ZONE t.timezone)::time <  s.quiet_hours_end)
       ELSE ((now() AT TIME ZONE t.timezone)::time >= s.quiet_hours_start
             AND (now() AT TIME ZONE t.timezone)::time <  s.quiet_hours_end)
  END                                      AS in_quiet_hours,
  (SELECT count(*) FROM conversations cv
     WHERE cv.tenant_id = t.id AND cv.contact_id = c.id
       AND cv.direction = 'inbound'
       AND cv.created_at > now() - interval '24 hours') AS inbound_24h
FROM tenants t
JOIN clinic_settings s ON s.tenant_id = t.id
JOIN contacts c        ON c.id = $2::uuid
WHERE t.id = $1::uuid;
```

Query Parameters (Expression mode, array form — same rule as Milestone A):

```
{{ [ $('PG Resolve Contact And Role').first().json.tenant_id, $('PG Resolve Contact And Role').first().json.contact_id ] }}
```

> The quiet-hours `CASE` handles the window crossing midnight (21:00 → 08:00). A
> naive `BETWEEN` returns false all night for that range. This query was run against
> your database and returns `in_quiet_hours: false` at 17:58 local.

---

### Node 6 — `FN Safety Gate`  (Code, Run Once for All Items)

Pure function. No database, no network, no model. Reads the context, returns a verdict.

```javascript
// FN Safety Gate
// DETERMINISTIC. The model is never consulted here and never will be.
// Returns exactly one verdict plus a reason_code from the fixed vocabulary
// in docs/02-NAMING-CONVENTIONS.md §7.

const gate = $input.first().json;                                   // PG Load Gate Context
const msg  = $('FN Normalize Inbound').first().json;
const who  = $('PG Resolve Contact And Role').first().json;
const role = who.actor_role;

// Normalise for keyword matching: letters and spaces only, collapsed.
const normalized = String(msg.message || '')
  .toUpperCase()
  .replace(/[^A-Z ]/g, '')
  .replace(/\s+/g, ' ')
  .trim();

// Exact single-phrase matches only.
// NOTE: 'CANCEL' is deliberately NOT an opt-out keyword here. In a booking
// bot, "cancel" almost always means "cancel my appointment". Treating it as
// an unsubscribe would silently mute patients who were trying to reschedule.
const OPT_OUT = ['STOP', 'STOPALL', 'UNSUBSCRIBE', 'OPTOUT', 'OPT OUT', 'QUIT', 'END'];
const OPT_IN  = ['START', 'UNSTOP', 'RESUME'];

let decision = 'allow';
let reason   = 'ok';
let reply    = null;

const isStaff = role === 'owner' || role === 'staff';

if (OPT_OUT.includes(normalized)) {
  // Always honoured, for everyone, immediately. No exceptions, no confirmation step.
  decision = 'opt_out';
  reason   = 'opt_out_requested';
  reply    = 'You have been unsubscribed and will not receive further messages. Reply START to resume.';

} else if (OPT_IN.includes(normalized) && gate.opted_out === true) {
  decision = 'opt_in';
  reason   = 'opt_in_requested';
  reply    = 'You are resubscribed. How can we help?';

} else if (gate.ai_paused === true) {
  // A human has taken this thread over. Stay silent so we don't talk over them.
  decision = 'block';
  reason   = 'escalated_requested';

} else if (!isStaff && gate.opted_out === true) {
  decision = 'block';
  reason   = 'opted_out';

} else if (!isStaff && Number(gate.inbound_24h) > Number(gate.max_msgs_per_contact_per_day)) {
  decision = 'block';
  reason   = 'rate_limited';
}

// Staff and owner bypass opt-out and rate limiting. They cannot unsubscribe
// from their own operations assistant, and they legitimately send bursts.
// They do NOT bypass ai_paused: if a human owns the thread, nobody automates it.

return [{
  json: {
    correlation_id: msg.correlation_id,
    tenant_id:      who.tenant_id,
    contact_id:     who.contact_id,
    actor_role:     role,
    gate_decision:  decision,          // allow | block | opt_out | opt_in
    reason_code:    reason,
    reply_text:     reply,             // null unless we owe a policy reply
    // carried for the audit row and for Milestone H
    in_quiet_hours: gate.in_quiet_hours,
    inbound_24h:    Number(gate.inbound_24h),
    local_time:     gate.local_time,
  },
}];
```

**Read the ordering once more.** Opt-out is checked *first*, before the
already-opted-out block. Otherwise a contact who is already opted out could never
send `START` to come back — they'd be blocked before the keyword was examined.
This kind of ordering bug is why the gate is one readable function rather than a
chain of IF nodes.

---

### Node 7 — `SW Gate Decision`  (Switch)

Mode: **Rules**. Value to match: `{{ $json.gate_decision }}`

| Output | Condition (String → equals) | Renames to |
|---|---|---|
| 0 | `opt_out` | `opt_out` |
| 1 | `opt_in` | `opt_in` |
| 2 | `block` | `block` |
| 3 | *Fallback Output → extra output* | `allow` |

Using the fallback for `allow` means a future decision value you forget to wire
still reaches a branch instead of silently vanishing.

---

### Node 8 — `PG Apply Opt Out`  (Postgres, Execute Query)

Wire this to outputs **0 (`opt_out`)** and **1 (`opt_in`)**. One node handles both —
the boolean it writes comes from the decision.

```sql
WITH upd AS (
  UPDATE contacts
     SET opted_out    = ($3 = 'opt_out'),
         opted_out_at = CASE WHEN $3 = 'opt_out' THEN now() ELSE NULL END,
         marketing_consent = CASE WHEN $3 = 'opt_out' THEN false ELSE marketing_consent END
   WHERE tenant_id = $1::uuid AND id = $2::uuid
  RETURNING id, opted_out
)
INSERT INTO consents (tenant_id, contact_id, channel, purpose, consent, source, evidence)
SELECT $1::uuid, $2::uuid, $4::channel_t, 'marketing',
       ($3 = 'opt_in'), $3,
       jsonb_build_object('message', $5, 'correlation_id', $6)
FROM upd
RETURNING contact_id, consent;
```

Query Parameters:

```
{{ [ $json.tenant_id, $json.contact_id, $json.gate_decision, $('FN Normalize Inbound').first().json.channel, $('FN Normalize Inbound').first().json.message, $json.correlation_id ] }}
```

Two things worth noticing:

- **`contacts.opted_out` is the fast flag; `consents` is the evidence.** The flag is
  what the gate reads on every message. The ledger is what you show someone who asks
  *"prove this person consented."* Never update `consents` — only insert.
- An opt-out also clears `marketing_consent`. An opt-in does **not** restore it —
  resuming service messages is not the same as re-consenting to marketing. That
  asymmetry is deliberate.

---

### Node 9 — `PG Write Audit Log`  (Postgres, Execute Query)

Connect **all four** switch branches to this node.

```sql
INSERT INTO audit_logs
  (tenant_id, contact_id, workflow, action, status, reason_code, correlation_id, details)
VALUES
  ($1::uuid, $2::uuid, 'WF-01', 'safety_gate', $3, $4, $5,
   jsonb_build_object(
     'actor_role',     $6,
     'channel',        $7,
     'in_quiet_hours', $8::boolean,
     'inbound_24h',    $9::int,
     'local_time',     $10
   ))
RETURNING id;
```

Query Parameters:

```
{{ [ $('FN Safety Gate').first().json.tenant_id, $('FN Safety Gate').first().json.contact_id, ($('FN Safety Gate').first().json.gate_decision === 'block' ? 'blocked' : 'ok'), $('FN Safety Gate').first().json.reason_code, $('FN Safety Gate').first().json.correlation_id, $('FN Safety Gate').first().json.actor_role, $('FN Normalize Inbound').first().json.channel, $('FN Safety Gate').first().json.in_quiet_hours, $('FN Safety Gate').first().json.inbound_24h, $('FN Safety Gate').first().json.local_time ] }}
```

Everything reads from `$('FN Safety Gate')` rather than `$json`, because `$json`
differs depending on which branch arrived. This is why that node returns a single
flat object with every field the rest of the workflow needs.

---

### Node 10 — `RESP Ack`  (existing, new body)

Switch Response Body to Expression mode and replace with:

```
{
  "ok": true,
  "correlation_id": "{{ $('FN Safety Gate').first().json.correlation_id }}",
  "contact_id": "{{ $('FN Safety Gate').first().json.contact_id }}",
  "actor_role": "{{ $('FN Safety Gate').first().json.actor_role }}",
  "gate_decision": "{{ $('FN Safety Gate').first().json.gate_decision }}",
  "reason_code": "{{ $('FN Safety Gate').first().json.reason_code }}",
  "reply_text": {{ JSON.stringify($('FN Safety Gate').first().json.reply_text) }}
}
```

`JSON.stringify` on `reply_text` handles it being `null` *and* escapes any quotes in
the text. Interpolating it raw would produce invalid JSON the moment the reply
contains an apostrophe.

---

## B4. Acceptance tests

Keep *Listen for test event* active and send each of these.

**1. Normal message → allowed**

```powershell
$body = '{"channel":"test","phone":"+12125550199","name":"Test Patient","message":"Can I book a cleaning?"}'
Invoke-RestMethod -Uri "http://localhost:5678/webhook-test/salesfixr/v1/inbound/test" -Method Post -ContentType "application/json" -Body $body
```
Expect `gate_decision: allow`, `reason_code: ok`, `reply_text: null`.

**2. STOP → opt-out applied**

```powershell
$body = '{"channel":"test","phone":"+12125550199","message":"STOP"}'
Invoke-RestMethod -Uri "http://localhost:5678/webhook-test/salesfixr/v1/inbound/test" -Method Post -ContentType "application/json" -Body $body
```
Expect `gate_decision: opt_out` and a `reply_text`. Then in Neon:

```sql
SELECT opted_out, opted_out_at, marketing_consent FROM contacts WHERE phone_e164 = '+12125550199';
SELECT purpose, consent, source FROM consents ORDER BY captured_at DESC LIMIT 2;
```
`opted_out` must be `true`, and a `consents` row must exist with `consent = false`.

**3. Message while opted out → blocked**

Send test 1 again. Expect `gate_decision: block`, `reason_code: opted_out`,
`reply_text: null`.

**4. START → resubscribed**

```powershell
$body = '{"channel":"test","phone":"+12125550199","message":"START"}'
Invoke-RestMethod -Uri "http://localhost:5678/webhook-test/salesfixr/v1/inbound/test" -Method Post -ContentType "application/json" -Body $body
```
Expect `gate_decision: opt_in`. `opted_out` back to `false`, `marketing_consent`
still `false`.

**5. "cancel" is NOT an opt-out**

```powershell
$body = '{"channel":"test","phone":"+12125550199","message":"I need to cancel my appointment"}'
Invoke-RestMethod -Uri "http://localhost:5678/webhook-test/salesfixr/v1/inbound/test" -Method Post -ContentType "application/json" -Body $body
```
Expect `gate_decision: allow`. If this returns `opt_out`, your keyword list is doing
substring matching instead of exact matching — check the `normalized` logic.

**6. Escalation pause → blocked**

```sql
UPDATE contacts SET ai_paused_until = now() + interval '10 minutes'
WHERE phone_e164 = '+12125550199';
```
Send test 1. Expect `reason_code: escalated_requested`. Then clean up:
```sql
UPDATE contacts SET ai_paused_until = NULL WHERE phone_e164 = '+12125550199';
```

**7. The audit trail** — the payoff for all of this:

```sql
SELECT created_at, status, reason_code, details->>'actor_role' AS role,
       details->>'inbound_24h' AS msgs_24h
FROM audit_logs WHERE workflow = 'WF-01'
ORDER BY created_at DESC LIMIT 10;
```

You should see one row per test above, with the right reason code. **This is the
screen you show a client.** It is the difference between "the AI handles it" and
"here is every decision the system made and why."

---

## Done when

- [ ] `ai_paused_until` column exists
- [ ] All 7 tests above produce the expected `reason_code`
- [ ] `consents` has an append-only trail of the opt-out and opt-in
- [ ] `audit_logs` has a row for every single message, allowed or blocked
- [ ] "cancel" still routes to `allow`
- [ ] Workflow exported to `workflows/exports/` and committed

**Next:** Milestone C — the AI, behind this wall. `docs/07-MILESTONE-C.md`.
